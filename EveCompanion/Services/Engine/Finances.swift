import Foundation

/// Originally `finances.py`: net worth, 30 days of ISK in / out, profit by activity
/// and your transactions. ESI keeps 30 days of journal and up to 2,500 recent transactions.
enum Finances {
    static let days = 30

    /// Wallet + items you own (CCP average prices) + sell orders still listed + buy-order escrow.
    static func netWorth(_ balance: Double) async throws -> JSONDict {
        let cid = try await EveAuth.shared.characterID()
        let prices = try await Market.averagePrices()

        let assets: [JSONDict] = (try? await ESI.getAssets()).map { Array($0.byItem.values) } ?? []
        let assetsValue = assets
            .filter { !$0.bool("is_blueprint_copy") }
            .reduce(0.0) { $0 + (prices[$1.int("type_id") ?? 0] ?? 0.0) * Double($1.int("quantity") ?? 1) }

        let orders = asDicts((try? await ESI.get("characters/\(cid)/orders/")) ?? [Any]())
        let sellOrders = orders.filter { !$0.bool("is_buy_order") }
            .reduce(0.0) { $0 + ($1.double("price") ?? 0) * Double($1.int("volume_remain") ?? 0) }
        let escrow = orders.filter { $0.bool("is_buy_order") }
            .reduce(0.0) { $0 + ($1.double("escrow") ?? 0.0) }

        return [
            "total": balance + assetsValue + sellOrders + escrow,
            "wallet": balance,
            "assets": assetsValue,
            "sell_orders": sellOrders,
            "escrow": escrow,
        ]
    }

    /// Ore mined in the range, valued at the hub's best buy order (CCP average if none).
    private static func mining(_ rows: [JSONDict], oreHub: String) async throws -> JSONDict {
        var totals: [Int: Int] = [:]
        var order: [Int] = []
        for row in rows {
            guard let typeID = row.int("type_id") else { continue }
            if totals[typeID] == nil { order.append(typeID) }
            totals[typeID, default: 0] += row.int("quantity") ?? 0
        }
        if totals.isEmpty { return ["value": 0.0, "units": 0, "ores": [JSONDict](), "monthly": [String: Double]()] }
        let books = try await Market.hubBooks(oreHub, totals.keys)
        let average = try await Market.averagePrices()
        let names = try SDE.typeNames(totals.keys)
        func price(_ typeID: Int) -> Double {
            let buy = books[typeID]?.double("buy").flatMap { $0 != 0 ? $0 : nil }
            return buy ?? average[typeID] ?? 0.0
        }
        var ores: [JSONDict] = order.map { typeID in
            let qty = totals[typeID] ?? 0
            let value: Double = Double(qty) * price(typeID)
            return ["name": names[typeID] ?? String(typeID), "units": qty, "value": value]
        }
        ores.sort { ($0.double("value") ?? 0) > ($1.double("value") ?? 0) }
        var monthly: [String: Double] = [:]
        for row in rows {
            guard let typeID = row.int("type_id"), let date = row.string("date") else { continue }
            monthly[String(date.prefix(7)), default: 0] += Double(row.int("quantity") ?? 0) * price(typeID)
        }
        return [
            "value": ores.reduce(0.0) { $0 + ($1.double("value") ?? 0) },
            "units": totals.values.reduce(0, +),
            "ores": ores,
            "monthly": monthly,
        ]
    }

    private static func thousands(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// Finances over the chosen history range, from the local history (Data/history.sqlite).
    static func summary(oreHub: String = "Jita", days: Int = HistoryRange.days) async throws -> JSONDict {
        await HistoryStore.shared.sync()
        let cid = try await EveAuth.shared.characterID()
        let now = Date()
        let since = HistoryRange.since(days, now: now)
        let sinceText: String? = since.map(ISODate.string)
        let sinceDay: String? = since.map(ISODate.day)
        let store = HistoryStore.shared

        let journal = try await store.query(
            "SELECT date, ref_type, amount FROM journal WHERE character_id = ? AND (? IS NULL OR date >= ?) ORDER BY date",
            [cid, sinceText, sinceText])
        let txns = try await store.query(
            "SELECT * FROM transactions WHERE character_id = ? AND (? IS NULL OR date >= ?) ORDER BY date DESC",
            [cid, sinceText, sinceText])
        let minedRows = try await store.query(
            "SELECT date, type_id, quantity FROM mining WHERE character_id = ? AND (? IS NULL OR date >= ?)",
            [cid, sinceDay, sinceDay])
        let worthRows = try await store.query(
            "SELECT date, wallet, total FROM daily WHERE character_id = ? AND (? IS NULL OR date >= ?) ORDER BY date",
            [cid, sinceDay, sinceDay])
        let firstJournal = try await store.query("SELECT MIN(date) AS first FROM journal WHERE character_id = ?", [cid])
            .first?.string("first")

        // ---- ISK in / out by category, day and month ----
        var income = 0.0, spending = 0.0
        var catOrder: [String] = []
        var catIncome: [String: Double] = [:], catSpending: [String: Double] = [:]
        var daily: [String: Double] = [:]
        var dailyIn: [String: Double] = [:], dailyOut: [String: Double] = [:]
        var monthIncome: [String: Double] = [:], monthSpending: [String: Double] = [:]
        for entry in journal {
            let amount = entry.double("amount") ?? 0
            let label = Wallet.categories[entry.string("ref_type") ?? ""] ?? "Other"
            if catIncome[label] == nil {
                catOrder.append(label)
                catIncome[label] = 0
                catSpending[label] = 0
            }
            let date = entry.string("date") ?? ""
            let month = String(date.prefix(7))
            if amount >= 0 {
                income += amount
                catIncome[label]! += amount
                monthIncome[month, default: 0] += amount
            } else {
                spending += -amount
                catSpending[label]! += -amount
                monthSpending[month, default: 0] += -amount
            }
            let dayKey = String(date.prefix(10))
            daily[dayKey, default: 0] += amount
            if amount >= 0 { dailyIn[dayKey, default: 0] += amount } else { dailyOut[dayKey, default: 0] += -amount }
        }

        // Every day from the start of the range (or of the data) to today, so the chart has no gaps.
        var dayRows: [JSONDict] = []
        let firstDay = sinceDay ?? firstJournal.map { String($0.prefix(10)) } ?? ISODate.day(now)
        var cursor = ISODate.parse(firstDay) ?? now
        while cursor <= now {
            let key = ISODate.day(cursor)
            let dayIn: Double = dailyIn[key] ?? 0
            let dayOut: Double = dailyOut[key] ?? 0
            dayRows.append(["date": key, "net": daily[key] ?? 0.0, "income": dayIn, "spending": dayOut])
            cursor = cursor.addingTimeInterval(86400)
        }

        let categoryRows: [JSONDict] = catOrder
            .map { ["name": $0, "income": catIncome[$0] ?? 0, "spending": catSpending[$0] ?? 0] as JSONDict }
            .sorted { -(($0.double("income") ?? 0) + ($0.double("spending") ?? 0))
                    < -(($1.double("income") ?? 0) + ($1.double("spending") ?? 0)) }

        // ---- Net worth (live) + its history ----
        let balance = ((try? await ESI.get("characters/\(cid)/wallet/")) as? NSNumber)?.doubleValue
            ?? worthRows.last?.double("wallet") ?? 0
        let worth = try await netWorth(balance)
        let worthHistory: [JSONDict] = worthRows.map {
            ["date": $0.string("date") ?? "", "total": $0.double("total") ?? 0, "wallet": $0.double("wallet") ?? 0]
        }

        // ---- What you build (products of your blueprints) and what goes into it ----
        let blueprintIDs = Set(((try? await ESI.characterBlueprints()) ?? []).compactMap { $0.int("type_id") })
        var products = Set<Int>(), materials = Set<Int>()
        if !blueprintIDs.isEmpty {
            let db = try SDE.connect()
            let ids = Array(blueprintIDs)
            let marks = placeholders(ids.count)
            products = Set(try db.query("SELECT product_type_id FROM bp_manufacturing WHERE blueprint_type_id IN (\(marks))", ids)
                .compactMap { $0.int("product_type_id") })
            materials = Set(try db.query("SELECT material_type_id FROM bp_materials WHERE blueprint_type_id IN (\(marks))", ids)
                .compactMap { $0.int("material_type_id") })
        }

        var buildSales = 0.0, buildBuys = 0.0, tradeSales = 0.0, tradeBuys = 0.0
        for t in txns {
            let value = Double(t.int("quantity") ?? 0) * (t.double("unit_price") ?? 0)
            let typeID = t.int("type_id") ?? 0
            if t.bool("is_buy") {
                if materials.contains(typeID) { buildBuys += value } else { tradeBuys += value }
            } else {
                if products.contains(typeID) { buildSales += value } else { tradeSales += value }
            }
        }

        func spent(_ name: String) -> Double { catSpending[name] ?? 0 }
        let jobFees = spent("Industry job fees")
        let marketFees = spent("Sales tax") + spent("Broker fees")
        let refineryTax = spent("Reprocessing tax")
        let mined = (try? await mining(minedRows, oreHub: oreHub))
            ?? ["value": 0.0, "units": 0, "ores": [JSONDict](), "monthly": [String: Double]()]
        let miningValue = mined.double("value") ?? 0
        let miningUnits = mined.int("units") ?? 0
        let miningMonthly = mined["monthly"] as? [String: Double] ?? [:]

        func line(_ name: String, _ amount: Double) -> JSONDict { ["name": name, "amount": amount] }
        func activity(_ name: String, income: Double, costs: Double, detail: String, lines: [JSONDict]) -> JSONDict {
            ["name": name, "income": income, "costs": costs, "detail": detail, "lines": lines, "net": income - costs]
        }
        let miningLines: [JSONDict] = mined.dicts("ores").prefix(6).map { ore in
            let name: String = ore.string("name") ?? ""
            let amount: Double = ore.double("value") ?? 0
            let units: Int = ore.int("units") ?? 0
            return ["name": name, "amount": amount, "units": units]
        }
        let manufacturingCosts: Double = buildBuys + jobFees
        let feeCosts: Double = marketFees + refineryTax
        let activities: [JSONDict] = [
            activity("Mining", income: miningValue, costs: 0.0,
                     detail: "\(thousands(miningUnits)) units of ore mined, valued at \(oreHub) buy orders (not cash until sold)",
                     lines: miningLines),
            activity("Manufacturing", income: buildSales, costs: manufacturingCosts,
                     detail: "Sales of items you have blueprints for, minus materials bought for them and industry job fees",
                     lines: [line("Sales", buildSales), line("Materials bought", -buildBuys), line("Job fees", -jobFees)]),
            activity("Trading", income: tradeSales, costs: tradeBuys,
                     detail: "Everything else you bought and sold on the market",
                     lines: [line("Sales", tradeSales), line("Purchases", -tradeBuys)]),
            activity("Fees & taxes", income: 0.0, costs: feeCosts,
                     detail: "Sales tax and broker fees on all market activity, plus refinery tax",
                     lines: [line("Sales tax + broker fees", -marketFees), line("Refinery tax", -refineryTax)]),
        ]

        // ---- Months ----
        let months = Set(monthIncome.keys).union(monthSpending.keys).union(miningMonthly.keys).sorted()
        let monthly: [JSONDict] = months.map { month in
            let monthIn: Double = monthIncome[month] ?? 0
            let monthOut: Double = monthSpending[month] ?? 0
            let minedValue: Double = miningMonthly[month] ?? 0
            return ["month": month, "income": monthIn, "spending": monthOut, "net": monthIn - monthOut, "mined": minedValue]
        }

        // ---- Transactions list, newest first, with names ----
        let typeNames = try SDE.typeNames(txns.compactMap { $0.int("type_id") })
        var places: [Int: String] = [:]
        for loc in Set(txns.compactMap { $0.int("location_id") }) {
            places[loc] = await ESI.placeName(loc)
        }
        let rows: [JSONDict] = txns.map { t in
            let typeID = t.int("type_id") ?? 0
            let quantity = t.int("quantity") ?? 0
            let unitPrice = t.double("unit_price") ?? 0
            let isBuy = t.bool("is_buy")
            let total: Double = Double(quantity) * unitPrice * (isBuy ? -1.0 : 1.0)
            let location: String? = t.int("location_id").flatMap { places[$0] }
            return [
                "transaction_id": t.int("transaction_id") as Any,
                "date": t.string("date") as Any,
                "type_id": typeID,
                "name": typeNames[typeID] ?? String(typeID),
                "quantity": quantity,
                "unit_price": unitPrice,
                "total": total,
                "is_buy": isBuy,
                "location": location as Any,
            ]
        }

        let net: Double = income - spending
        return [
            "days": days,
            "range_label": HistoryRange.label(days),
            "history_since": firstJournal as Any,
            "net_worth": worth,
            "net_worth_history": worthHistory,
            "income": income,
            "spending": spending,
            "net": net,
            "daily": dayRows,
            "monthly": monthly,
            "categories": categoryRows,
            "activities": activities,
            "transactions": rows,
        ]
    }
}
