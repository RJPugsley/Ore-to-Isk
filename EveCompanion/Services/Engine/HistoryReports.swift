import Foundation

/// Reports built from the local history: real profit per product (average-cost stock pools),
/// results of finished market orders, completed industry jobs and net worth over time.
enum HistoryReports {

    // MARK: - Real profit per product (average cost)

    /// Rules (agreed with the user):
    /// - Materials you bought cost what you paid. Anything you didn't buy (mined ore, reprocessed
    ///   minerals, stock you already had) is free.
    /// - Each material has one pool; using it takes the pool's average cost.
    /// - Refinery tax paid is added to the next build that uses free (unbought) materials.
    /// - A build costs its materials + its job fee; built items go into their own pool.
    /// - A sale takes built items at their average cost; sales tax + broker fee use today's skills and standings at your trade hub.
    /// ESI doesn't say which units a job used, so this is an estimate from purchases and jobs.
    static func trackRecord(days: Int = HistoryRange.days) async throws -> [Int: JSONDict] {
        let cid = try await EveAuth.shared.characterID()
        let store = HistoryStore.shared
        let since = HistoryRange.since(days).map(ISODate.string)

        let txns = try await store.query(
            "SELECT date, type_id, quantity, unit_price, is_buy FROM transactions WHERE character_id = ?", [cid])
        let jobs = try await store.query(
            "SELECT * FROM jobs WHERE character_id = ? AND activity_id = 1 AND status != 'cancelled'", [cid])
        let taxes = try await store.query(
            "SELECT date, amount FROM journal WHERE character_id = ? AND ref_type = 'reprocessing_tax'", [cid])

        // Fee rates (today's skills and standings, broker fee at your trade hub).
        let levels = (try? await Market.skillLevels()) ?? [:]
        let accounting = Double((try? Reprocessing.level(levels, "Accounting")) ?? 0)
        let salesTaxRate = 0.075 * (1 - 0.11 * accounting)
        let standingMap = (try? await Market.standings()) ?? [:]
        var brokerRate = 0.03
        let sellHub = UserDefaults.standard.string(forKey: "build.materialHub") ?? "Jita"
        if let hub = try? await Market.hub(sellHub),
           let fee = try? IndustryCalc.brokerFee(levels, hub, standingMap) {
            brokerRate = fee
        }
        let feeRate = salesTaxRate + brokerRate

        enum Kind: Int { case buy = 0, tax = 1, start = 2, finish = 3, sell = 4 }
        struct Event { let date: String; let kind: Kind; let row: JSONDict }
        var events: [Event] = []
        for t in txns {
            events.append(Event(date: t.string("date") ?? "", kind: t.bool("is_buy") ? .buy : .sell, row: t))
        }
        for t in taxes { events.append(Event(date: t.string("date") ?? "", kind: .tax, row: t)) }
        let nowText = ISODate.string(Date())
        for j in jobs {
            events.append(Event(date: j.string("start_date") ?? "", kind: .start, row: j))
            if let end = j.string("end_date"), end <= nowText {
                events.append(Event(date: end, kind: .finish, row: j))
            }
        }
        events.sort { ($0.date, $0.kind.rawValue) < ($1.date, $1.kind.rawValue) }

        var pools: [Int: (qty: Double, cost: Double)] = [:]
        var pendingTax = 0.0
        var jobCosts: [Int: Double] = [:]
        var manufacturing: [Int: JSONDict] = [:]
        var stats: [Int: JSONDict] = [:]
        var firstDate: String?

        func blueprint(_ id: Int) -> JSONDict? {
            if let cached = manufacturing[id] { return cached }
            let data = (try? SDE.manufacturing(id)) ?? nil
            if let data { manufacturing[id] = data }
            return data
        }
        func add(_ product: Int, _ key: String, _ value: Double) {
            var row = stats[product] ?? [:]
            row[key] = (row.double(key) ?? 0) + value
            stats[product] = row
        }

        for event in events {
            let r = event.row
            if firstDate == nil { firstDate = event.date }
            let inRange = since.map { event.date >= $0 } ?? true
            switch event.kind {
            case .buy:
                let type = r.int("type_id") ?? 0
                let qty = Double(r.int("quantity") ?? 0)
                var pool = pools[type] ?? (0, 0)
                pool.qty += qty
                pool.cost += qty * (r.double("unit_price") ?? 0)
                pools[type] = pool

            case .tax:
                pendingTax += -(r.double("amount") ?? 0)

            case .start:
                guard let bpType = r.int("blueprint_type_id"), let data = blueprint(bpType) else { continue }
                let runs = r.int("runs") ?? 1
                let materialMod = 1 - Double(r.int("me") ?? 0) / 100
                var cost = 0.0
                var usedFree = false
                for m in data.dicts("materials") {
                    let type = m.int("material_type_id") ?? 0
                    let base = m.int("quantity") ?? 0
                    let required = Double(max(runs, IndustryCalc.ceilRounded(Double(runs * base) * materialMod)))
                    var pool = pools[type] ?? (0, 0)
                    let take = min(required, pool.qty)
                    if take > 0 {
                        let part = pool.cost / pool.qty * take
                        cost += part
                        pool.qty -= take
                        pool.cost -= part
                        pools[type] = pool
                    }
                    if required > take { usedFree = true }
                }
                if usedFree {
                    cost += pendingTax
                    pendingTax = 0
                }
                cost += r.double("cost") ?? 0
                jobCosts[r.int("job_id") ?? 0] = cost

            case .finish:
                guard let bpType = r.int("blueprint_type_id"), let data = blueprint(bpType),
                      let product = r.int("product_type_id") ?? data.dict("blueprint")?.int("product_type_id") else { continue }
                let perRun = data.dict("blueprint")?.int("product_quantity") ?? 1
                let units = Double((r.int("successful_runs") ?? r.int("runs") ?? 1) * perRun)
                let cost = jobCosts[r.int("job_id") ?? 0] ?? 0
                var pool = pools[product] ?? (0, 0)
                pool.qty += units
                pool.cost += cost
                pools[product] = pool
                if inRange {
                    add(product, "built_units", units)
                    add(product, "build_cost", cost)
                    add(product, "jobs", 1)
                } else if stats[product] == nil {
                    stats[product] = [:]
                }

            case .sell:
                let type = r.int("type_id") ?? 0
                guard stats[type] != nil else {
                    // Not something you've built (yet) – just leaves stock.
                    var pool = pools[type] ?? (0, 0)
                    let take = min(Double(r.int("quantity") ?? 0), pool.qty)
                    if take > 0 {
                        pool.cost -= pool.cost / pool.qty * take
                        pool.qty -= take
                        pools[type] = pool
                    }
                    continue
                }
                let qty = Double(r.int("quantity") ?? 0)
                let price = r.double("unit_price") ?? 0
                var pool = pools[type] ?? (0, 0)
                let take = min(qty, pool.qty)
                var costOfSold = 0.0
                if take > 0 {
                    costOfSold = pool.cost / pool.qty * take
                    pool.qty -= take
                    pool.cost -= costOfSold
                    pools[type] = pool
                }
                if inRange {
                    let revenue = take * price
                    add(type, "sold_units", take)
                    add(type, "revenue", revenue)
                    add(type, "fees", revenue * feeRate)
                    add(type, "cost_of_sold", costOfSold)
                    add(type, "untracked_sold", qty - take)
                }
            }
        }

        var result: [Int: JSONDict] = [:]
        for (product, row) in stats {
            let built = row.double("built_units") ?? 0
            let buildCost = row.double("build_cost") ?? 0
            let sold = row.double("sold_units") ?? 0
            let revenue = row.double("revenue") ?? 0
            let fees = row.double("fees") ?? 0
            let costOfSold = row.double("cost_of_sold") ?? 0
            let profit: Double = revenue - fees - costOfSold
            let pool = pools[product] ?? (0, 0)
            result[product] = [
                "product_type_id": product,
                "jobs": Int(row.double("jobs") ?? 0),
                "built_units": Int(built),
                "build_cost": buildCost,
                "cost_per_unit": (built > 0 ? buildCost / built : nil) as Double? as Any,
                "sold_units": Int(sold),
                "untracked_sold": Int(row.double("untracked_sold") ?? 0),
                "revenue": revenue,
                "average_sale_price": (sold > 0 ? revenue / sold : nil) as Double? as Any,
                "fees": fees,
                "fee_rate": feeRate,
                "cost_of_sold": costOfSold,
                "profit": profit,
                "profit_per_unit": (sold > 0 ? profit / sold : nil) as Double? as Any,
                "in_stock": Int(pool.qty.rounded()),
                "in_stock_cost": pool.cost,
                "data_since": firstDate as Any,
                "range_label": HistoryRange.label(days),
            ]
        }
        return result
    }

    // MARK: - Finished market orders

    static func orderResults(days: Int = HistoryRange.days) async throws -> JSONDict {
        await HistoryStore.shared.sync()
        let cid = try await EveAuth.shared.characterID()
        let store = HistoryStore.shared
        let since = HistoryRange.since(days)
        let sinceText = since.map(ISODate.string)

        let orders = try await store.query(
            "SELECT * FROM orders WHERE character_id = ? AND state != 'open' AND (? IS NULL OR issued >= ?) ORDER BY issued DESC",
            [cid, sinceText, sinceText])
        let txns = try await store.query(
            "SELECT date, type_id, quantity, unit_price, is_buy, location_id FROM transactions WHERE character_id = ? AND (? IS NULL OR date >= ?)",
            [cid, sinceText, sinceText])
        let names = try SDE.typeNames(orders.compactMap { $0.int("type_id") })
        var places: [Int: String] = [:]
        for loc in Set(orders.compactMap { $0.int("location_id") }) { places[loc] = await ESI.placeName(loc) }

        var rows: [JSONDict] = []
        var filled = 0, partly = 0, unsold = 0, cancelled = 0
        var hoursToFill: [Double] = []
        var gotValue = 0.0, listedValue = 0.0
        for o in orders {
            let typeID = o.int("type_id") ?? 0
            let total = o.int("volume_total") ?? 0
            let remain = o.int("volume_remain") ?? 0
            let soldUnits = total - remain
            let isBuy = o.bool("is_buy")
            let price = o.double("price") ?? 0
            let state = o.string("state") ?? ""
            let issued = ISODate.parse(o.string("issued")) ?? Date()
            let expires = issued.addingTimeInterval(Double(o.int("duration") ?? 90) * 86400)

            // Your trades of this item at this station while the order was up.
            let matches = txns.filter { t in
                t.int("type_id") == typeID && t.int("location_id") == o.int("location_id") && t.bool("is_buy") == isBuy
                    && (ISODate.parse(t.string("date")).map { $0 >= issued && $0 <= expires } ?? false)
            }
            let matchedUnits = matches.reduce(0) { $0 + ($1.int("quantity") ?? 0) }
            let matchedValue = matches.reduce(0.0) { $0 + Double($1.int("quantity") ?? 0) * ($1.double("unit_price") ?? 0) }
            let lastTrade = matches.compactMap { ISODate.parse($0.string("date")) }.max()

            let outcome: String
            if soldUnits >= total && total > 0 {
                outcome = "Filled"
                filled += 1
                if let lastTrade { hoursToFill.append(lastTrade.timeIntervalSince(issued) / 3600) }
            } else if soldUnits > 0 {
                outcome = "Part filled"
                partly += 1
            } else if state == "cancelled" {
                outcome = "Cancelled"
                cancelled += 1
            } else {
                outcome = isBuy ? "Expired unfilled" : "Expired unsold"
                unsold += 1
            }
            if matchedUnits > 0 {
                gotValue += matchedValue
                listedValue += Double(matchedUnits) * price
            }
            let averagePrice: Double? = matchedUnits > 0 ? matchedValue / Double(matchedUnits) : nil
            let finished: Date = (soldUnits >= total ? lastTrade : nil) ?? min(expires, Date())
            rows.append([
                "order_id": o.int("order_id") as Any,
                "type_id": typeID,
                "name": names[typeID] ?? String(typeID),
                "station": o.int("location_id").flatMap { places[$0] } as Any,
                "is_buy": isBuy,
                "price": price,
                "volume_total": total,
                "units_traded": soldUnits,
                "outcome": outcome,
                "issued": o.string("issued") as Any,
                "finished": ISODate.string(finished),
                "average_trade_price": averagePrice as Any,
            ])
        }

        // How often and by how much you were beaten when Market Orders checked.
        let checks = try await store.query(
            "SELECT price, best_other, beaten FROM order_checks WHERE character_id = ? AND (? IS NULL OR time >= ?)",
            [cid, since?.timeIntervalSince1970, since?.timeIntervalSince1970])
        let beaten = checks.filter { $0.bool("beaten") }
        let gaps = beaten.compactMap { c -> Double? in
            guard let price = c.double("price"), price > 0, let other = c.double("best_other") else { return nil }
            return abs(price - other) / price
        }

        let averageHours: Double? = hoursToFill.isEmpty ? nil : hoursToFill.reduce(0, +) / Double(hoursToFill.count)
        let gotVsListed: Double? = listedValue > 0 ? gotValue / listedValue : nil
        let beatenShare: Double? = checks.isEmpty ? nil : Double(beaten.count) / Double(checks.count)
        let averageGap: Double? = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
        return [
            "range_label": HistoryRange.label(days),
            "finished": orders.count,
            "filled": filled,
            "part_filled": partly,
            "unsold": unsold,
            "cancelled": cancelled,
            "average_hours_to_fill": averageHours as Any,
            "got_vs_listed": gotVsListed as Any,
            "checks": checks.count,
            "beaten_share": beatenShare as Any,
            "average_gap": averageGap as Any,
            "orders": rows,
        ]
    }

    // MARK: - Completed industry jobs

    static func completedJobs(days: Int = HistoryRange.days) async throws -> JSONDict {
        await HistoryStore.shared.sync()
        let cid = try await EveAuth.shared.characterID()
        let sinceText = HistoryRange.since(days).map(ISODate.string)
        let jobs = try await HistoryStore.shared.query("""
            SELECT * FROM jobs WHERE character_id = ? AND status NOT IN ('active', 'paused')
            AND (? IS NULL OR end_date >= ?) ORDER BY end_date DESC
            """, [cid, sinceText, sinceText])
        let typeIDs = jobs.compactMap { $0.int("product_type_id") ?? $0.int("blueprint_type_id") }
        let names = try SDE.typeNames(typeIDs)
        var places: [Int: String] = [:]
        for loc in Set(jobs.compactMap { $0.int("facility_id") }) { places[loc] = await ESI.placeName(loc) }

        var monthRuns: [String: Int] = [:], monthCost: [String: Double] = [:], monthJobs: [String: Int] = [:]
        let rows: [JSONDict] = jobs.map { j in
            let typeID = j.int("product_type_id") ?? j.int("blueprint_type_id") ?? 0
            let runs = j.int("successful_runs") ?? j.int("runs") ?? 0
            let cost = j.double("cost") ?? 0
            let month = String((j.string("end_date") ?? "").prefix(7))
            if j.int("activity_id") == 1 && j.string("status") != "cancelled" {
                monthRuns[month, default: 0] += runs
                monthCost[month, default: 0] += cost
                monthJobs[month, default: 0] += 1
            }
            return [
                "job_id": j.int("job_id") as Any,
                "activity_id": j.int("activity_id") ?? 0,
                "type_id": typeID,
                "name": names[typeID] ?? String(typeID),
                "runs": runs,
                "cost": cost,
                "end_date": j.string("end_date") as Any,
                "status": j.string("status") ?? "",
                "location": j.int("facility_id").flatMap { places[$0] } as Any,
            ]
        }
        let monthly: [JSONDict] = monthRuns.keys.sorted().map { month in
            ["month": month, "runs": monthRuns[month] ?? 0, "jobs": monthJobs[month] ?? 0, "cost": monthCost[month] ?? 0]
        }
        return ["range_label": HistoryRange.label(days), "jobs": rows, "monthly": monthly]
    }

    // MARK: - Net worth over time

    static func netWorthHistory(days: Int = HistoryRange.days) async throws -> [JSONDict] {
        await HistoryStore.shared.sync()
        let cid = try await EveAuth.shared.characterID()
        let sinceDay = HistoryRange.since(days).map(ISODate.day)
        return try await HistoryStore.shared.query(
            "SELECT date, wallet, total FROM daily WHERE character_id = ? AND (? IS NULL OR date >= ?) ORDER BY date",
            [cid, sinceDay, sinceDay])
    }
}
