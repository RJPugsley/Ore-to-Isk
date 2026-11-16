import Foundation

/// Originally `build_vs_sell.py`: for any blueprint, is building the item worth more
/// than just selling the materials it needs?
///
///   materials if sold = Σ materials needed × material hub buy price × (1 − sales tax)
///   product sale      = sell hub's sell price × units per run × (1 − broker fee − sales tax)
///
/// Prices go through FairPrice: depth-priced for a batch of `batchRuns` runs, checked against
/// the region's median, and capped when they look inflated.
///   build gain        = product sale − job fee − materials if sold      (per run)
enum BuildVsSell {
    static let defaultLimit = 150
    static let inventedME = 2, inventedTE = 4
    static let junkBuyRatio = 0.1 // buy orders under 10% of CCP's adjusted price are ignored

    static func tech(_ metaGroupID: Int?) -> String {
        switch metaGroupID {
        case nil, 1: return "T1"
        case 2: return "T2"
        case 14: return "T3"
        case 4: return "Faction"
        case 3: return "Storyline"
        case 5: return "Officer"
        case 6: return "Deadspace"
        default: return "T1"
        }
    }

    /// Owned blueprint: best one you own of each type.
    struct Owned {
        let me: Int
        let te: Int
        let isCopy: Bool
    }

    private static func ownedSQL<S: Sequence>(_ ids: S) -> String where S.Element == Int {
        let text = ids.map(String.init).joined(separator: ",")
        return text.isEmpty ? "-1" : text
    }

    /// Blueprints worth listing: sold on the market, or a T2/T3 product (their blueprints aren't sold).
    private static func listable(_ owned: String) -> String {
        """
        p.published = 1 AND b.published = 1
                       AND (b.market_group_id IS NOT NULL OR p.meta_group_id IN (2, 14)
                            OR m.blueprint_type_id IN (\(owned)))
        """
    }

    /// [{name, count, groups: [{name, count}]}] of everything that can be built, biggest first.
    static func categories<S: Sequence>(_ ownedIDs: S) throws -> [JSONDict] where S.Element == Int {
        let rows = try SDE.connect().query("""
            SELECT c.name AS category, g.name AS grp, COUNT(*) AS n
            FROM bp_manufacturing m
            JOIN types p ON p.type_id = m.product_type_id
            JOIN types b ON b.type_id = m.blueprint_type_id
            JOIN groups g ON g.group_id = p.group_id
            JOIN categories c ON c.category_id = p.category_id
            WHERE \(listable(ownedSQL(ownedIDs)))
            GROUP BY c.name, g.name
            """)
        var order: [String] = []
        var counts: [String: Int] = [:]
        var groups: [String: [(String, Int)]] = [:]
        for r in rows {
            let cat = r.string("category") ?? ""
            if counts[cat] == nil { order.append(cat) }
            let n = r.int("n") ?? 0
            counts[cat, default: 0] += n
            groups[cat, default: []].append((r.string("grp") ?? "", n))
        }
        return order
            .sorted { (-(counts[$0] ?? 0), $0) < (-(counts[$1] ?? 0), $1) }
            .map { cat in
                let sortedGroups = (groups[cat] ?? []).sorted { (-$0.1, $0.0) < (-$1.1, $1.0) }
                return [
                    "name": cat,
                    "count": counts[cat] ?? 0,
                    "groups": sortedGroups.map { ["name": $0.0, "count": $0.1] as JSONDict },
                ] as JSONDict
            }
    }

    private static func candidates(_ category: String?, _ group: String?, _ search: String,
                                   _ ownedIDs: [Int], _ ownedOnly: Bool) throws -> [JSONDict] {
        var whereParts = [listable(ownedSQL(ownedIDs))]
        var params: [Any?] = []
        if let category, !category.isEmpty {
            whereParts.append("c.name = ?")
            params.append(category)
        }
        if let group, !group.isEmpty {
            whereParts.append("g.name = ?")
            params.append(group)
        }
        if !search.isEmpty {
            whereParts.append("(p.name LIKE ? OR b.name LIKE ?)")
            params += ["%\(search)%", "%\(search)%"]
        }
        if ownedOnly {
            whereParts.append("m.blueprint_type_id IN (\(ownedSQL(ownedIDs)))")
        }
        let db = try SDE.connect()
        let rows = try db.query("""
            SELECT m.blueprint_type_id, m.product_type_id, m.product_quantity, m.time,
                   p.name AS product_name, p.meta_group_id, g.name AS group_name,
                   c.name AS category_name
            FROM bp_manufacturing m
            JOIN types p ON p.type_id = m.product_type_id
            JOIN types b ON b.type_id = m.blueprint_type_id
            JOIN groups g ON g.group_id = p.group_id
            JOIN categories c ON c.category_id = p.category_id
            WHERE \(whereParts.joined(separator: " AND "))
            ORDER BY (p.name = ?) DESC, p.name
            """, params + [search])
        let materialQuery = try db.prepare(
            "SELECT material_type_id, quantity FROM bp_materials WHERE blueprint_type_id = ?")
        var result: [JSONDict] = []
        for r in rows {
            let mats = try materialQuery.rows([r.int("blueprint_type_id")])
            if !mats.isEmpty {
                var row = r
                row["materials"] = mats
                result.append(row)
            }
        }
        return result
    }

    /// sell_hub: "best" (highest wallet figure of all five hubs) or a hub name.
    static func compare(
        category: String? = "Ship",
        group: String? = nil,
        search: String = "",
        ownedOnly: Bool = false,
        ownedBlueprints: [Int: Owned] = [:],
        defaultME: Int = 0,
        defaultTE: Int = 0,
        systemID: Int? = nil,
        structure: String = "npc",
        rigME: Double = 0.0,
        rigTE: Double = 0.0,
        facilityTax facilityTaxIn: Double? = nil,
        materialHub: String = "Jita",
        sellHub: String = "best",
        limit: Int = defaultLimit,
        fresh: Bool = false,
        priceBand: Double? = nil,
        lookbackDays: Int? = nil,
        batchRuns: Int? = nil,
        batchTotals: Bool = false
    ) async throws -> JSONDict {
        // Price checks: the app-wide Price Checks menu unless the caller says otherwise.
        var settingsDraft = FairPrice.Settings.current
        if let priceBand { settingsDraft.band = priceBand }
        if let lookbackDays { settingsDraft.lookbackDays = lookbackDays }
        if let batchRuns { settingsDraft.batchRuns = batchRuns }
        settingsDraft.band = max(0.05, settingsDraft.band)
        settingsDraft.lookbackDays = max(7, settingsDraft.lookbackDays)
        let fairSettings = settingsDraft
        let runs = max(1, settingsDraft.batchRuns)
        // batchTotals: every figure is for the whole batch (Build vs Sell's Runs box).
        // Otherwise figures are per run (Blueprint Payback divides by them) – prices are
        // still depth-checked for the batch either way.
        let totalRuns = batchTotals ? runs : 1
        let bonuses = IndustryCalc.structures[structure] ?? IndustryCalc.structures["npc"]!
        let facilityTax = facilityTaxIn ?? (structure == "npc" ? IndustryCalc.npcFacilityTax * 100 : 0.0)

        let levels = try await Market.skillLevels()
        let standingMap = (try? await Market.standings()) ?? [:]

        let accounting = Double(try IndustryCalc.skillLevel(levels, "Accounting"))
        let salesTax = 0.075 * (1 - 0.11 * accounting)
        let industry = Double(try IndustryCalc.skillLevel(levels, "Industry"))
        let advanced = Double(try IndustryCalc.skillLevel(levels, "Advanced Industry"))
        let allHubs = try await Market.hubs()
        var brokers: [String: Double] = [:]
        for h in allHubs {
            brokers[h.string("name") ?? ""] = try IndustryCalc.brokerFee(levels, h, standingMap)
        }
        let sellHubs: [String]
        if !sellHub.isEmpty, sellHub.lowercased() != "best" {
            sellHubs = [try await Market.hub(sellHub).string("name") ?? sellHub]
        } else {
            sellHubs = allHubs.compactMap { $0.string("name") }
        }

        let adjusted = try await Market.adjustedPrices()
        var costIndex = 0.0
        if let systemID, systemID != 0 {
            costIndex = try await Market.costIndices()[systemID]?["manufacturing"] ?? 0.0
        }
        let feeRate = costIndex * (1 - bonuses.fee) + facilityTax / 100 + IndustryCalc.sccSurcharge

        let allCandidates = try candidates(category, group, search.trimmingCharacters(in: .whitespaces),
                                           Array(ownedBlueprints.keys), ownedOnly)
        let total = allCandidates.count
        let list = Array(allCandidates.prefix(limit))

        var materialIDs = Set<Int>()
        for c in list {
            for m in c.dicts("materials") { if let id = m.int("material_type_id") { materialIDs.insert(id) } }
        }
        let productIDs = Set(list.compactMap { $0.int("product_type_id") })
        if fresh { // Refresh Prices: ignore the 5-minute cache
            try await Market.forgetBooks([materialHub], materialIDs)
            try await Market.forgetBooks(sellHubs, productIDs)
        }
        let materialFetch = try await Market.hubBooksAllowingGaps(materialHub, materialIDs)
        let materialBooks = materialFetch.books
        var priceGaps = materialFetch.failed.count
        let names = try SDE.typeNames(materialIDs)
        let materialIDList = Array(materialIDs)
        let materialHistoryList = try await concurrentMap(materialIDList, limit: 16) { id -> JSONDict? in
            try? await Market.hubHistory(materialHub, id, days: fairSettings.lookbackDays)
        }
        var materialHistories: [Int: JSONDict] = [:]
        for (id, history) in zip(materialIDList, materialHistoryList) {
            if let history { materialHistories[id] = history }
        }

        /// What `quantity` units would sell for into buy orders, checked against history.
        /// No usable buy orders (or only junk "lowball" ones far below CCP's adjusted price)
        /// → the adjusted price is used and the material counts as unpriced.
        func materialPrice(_ typeID: Int, _ quantity: Int) -> (price: Double, fromMarket: Bool, status: String) {
            let reference = adjusted[typeID] ?? 0.0
            var live: Double?
            if let book = materialBooks[typeID] {
                live = FairPrice.buyDepthPrice(book, quantity: quantity) ?? book.double("buy")
            }
            guard let price = live, reference <= 0 || price >= reference * junkBuyRatio else {
                return (reference, false, "no_orders")
            }
            let checked = FairPrice.check(live: price, history: materialHistories[typeID],
                                          quantity: quantity, settings: fairSettings)
            return (checked.double("used") ?? price, true, checked.string("status") ?? "ok")
        }

        // Order books for every product at the chosen hub(s), in parallel (cached for 5 minutes).
        struct Job: Hashable { let type: Int; let hub: String }
        let jobs = list.flatMap { c in sellHubs.map { Job(type: c.int("product_type_id") ?? 0, hub: $0) } }
        let fetched = try await concurrentMap(jobs, limit: 16) { job -> JSONDict? in
            try? await Market.hubBook(job.hub, job.type)   // one timeout shouldn't sink the page
        }
        var books: [Job: JSONDict] = [:]
        for (job, book) in zip(jobs, fetched) {
            if let book { books[job] = book } else { priceGaps += 1 }
        }

        /// Sale price per unit at one hub for a batch: depth price of the cheapest sell orders.
        func liveSellPrice(_ book: JSONDict, _ units: Int) -> Double? {
            FairPrice.sellDepthPrice(book, quantity: units) ?? book.double("sell")
        }

        // First pick: the hub with the best raw net per product (no history needed yet).
        struct Pick { let hub: String; let raw: Double; let net: Double }
        var firstPick: [Int: Pick] = [:]
        for c in list {
            let productID = c.int("product_type_id") ?? 0
            let batchUnits = (c.int("product_quantity") ?? 1) * runs
            for hubName in sellHubs {
                guard let book = books[Job(type: productID, hub: hubName)],
                      let price = liveSellPrice(book, batchUnits) else { continue }
                let net = price * (1 - (brokers[hubName] ?? 0) - salesTax)
                if firstPick[productID] == nil || net > firstPick[productID]!.net {
                    firstPick[productID] = Pick(hub: hubName, raw: price, net: net)
                }
            }
        }

        // History at the picked hub (cached 6 hours). If that price looks inflated and other
        // hubs are in play, check them too so the best *believable* hub wins.
        let pickedJobs = firstPick.map { Job(type: $0.key, hub: $0.value.hub) }
        let pickedHistories = try await concurrentMap(pickedJobs, limit: 16) { job -> JSONDict? in
            try? await Market.hubHistory(job.hub, job.type, days: fairSettings.lookbackDays)
        }
        var productHistories: [Job: JSONDict] = [:]
        for (job, history) in zip(pickedJobs, pickedHistories) {
            if let history { productHistories[job] = history }
        }
        if sellHubs.count > 1 {
            var extraJobs: [Job] = []
            for c in list {
                let productID = c.int("product_type_id") ?? 0
                guard let pick = firstPick[productID] else { continue }
                let batchUnits = (c.int("product_quantity") ?? 1) * runs
                let checked = FairPrice.check(live: pick.raw, history: productHistories[Job(type: productID, hub: pick.hub)],
                                              quantity: batchUnits, settings: fairSettings)
                if checked.string("status") == "inflated" {
                    for hubName in sellHubs where hubName != pick.hub {
                        if books[Job(type: productID, hub: hubName)]?.double("sell") != nil {
                            extraJobs.append(Job(type: productID, hub: hubName))
                        }
                    }
                }
            }
            let extraHistories = try await concurrentMap(extraJobs, limit: 16) { job -> JSONDict? in
                try? await Market.hubHistory(job.hub, job.type, days: fairSettings.lookbackDays)
            }
            for (job, history) in zip(extraJobs, extraHistories) {
                if let history { productHistories[job] = history }
            }
        }

        var rows: [JSONDict] = []
        for c in list {
            let blueprintID = c.int("blueprint_type_id") ?? 0
            let productID = c.int("product_type_id") ?? 0
            let owned = ownedBlueprints[blueprintID]
            let techName = tech(c.int("meta_group_id"))
            var me = defaultME
            var te = defaultTE
            if let owned {
                me = owned.me
                te = owned.te
            } else if techName == "T2" {
                me = inventedME
                te = inventedTE
            }
            let materialMod = (1 - Double(me) / 100) * (1 - bonuses.me) * (1 - rigME / 100)

            var materialsIfSold = 0.0
            var eiv = 0.0
            var needs: [JSONDict] = []
            var unpriced = 0
            var materialFlags: [JSONDict] = []
            for m in c.dicts("materials") {
                let typeID = m.int("material_type_id") ?? 0
                let quantity = m.int("quantity") ?? 0
                // The game's rounding for a multi-run job: max(runs, ceil(round(runs × qty × mods, 2))).
                let required = max(totalRuns, IndustryCalc.ceilRounded(Double(totalRuns * quantity) * materialMod))
                let perRunRequired = max(1, IndustryCalc.ceilRounded(Double(quantity) * materialMod))
                let priced = materialPrice(typeID, batchTotals ? required : perRunRequired * runs)
                if !priced.fromMarket { unpriced += 1 }
                if priced.status == "inflated" || priced.status == "dumped" {
                    materialFlags.append(["name": names[typeID] ?? "", "status": priced.status])
                }
                materialsIfSold += Double(required) * priced.price * (1 - salesTax)
                eiv += Double(quantity * totalRuns) * (adjusted[typeID] ?? 0.0)
                needs.append(["name": names[typeID] ?? "", "quantity": required])
            }
            let jobFee = eiv * feeRate

            let seconds = Double((c.int("time") ?? 0) * totalRuns) * (1 - Double(te) / 100) * (1 - 0.04 * industry)
                * (1 - 0.03 * advanced) * (1 - bonuses.te) * (1 - rigTE / 100)

            // Best hub by the checked (believable) price. Hubs without history checked are
            // only considered when they are the first pick.
            var best: (hub: String, price: Double, net: Double, competition: Int, check: JSONDict, spread: String?)?
            let unitsPerRun = c.int("product_quantity") ?? 1
            let batchUnits = unitsPerRun * runs
            for hubName in sellHubs {
                let job = Job(type: productID, hub: hubName)
                guard let book = books[job], let lowest = book.double("sell"),
                      let live = liveSellPrice(book, batchUnits) else { continue }
                let isFirstPick = firstPick[productID]?.hub == hubName
                guard isFirstPick || productHistories[job] != nil else { continue }
                let checked = FairPrice.check(live: live, history: productHistories[job],
                                              quantity: batchUnits, settings: fairSettings)
                let used = checked.double("used") ?? live
                let net = used * Double(unitsPerRun * totalRuns) * (1 - (brokers[hubName] ?? 0) - salesTax)
                if best == nil || net > best!.net {
                    best = (hubName, lowest, net, book.int("sell_volume") ?? 0, checked, FairPrice.spread(book))
                }
            }

            let gain = best.map { $0.net - jobFee - materialsIfSold }
            let hours: Double? = seconds != 0 ? seconds / 3600 : nil
            var gainPerHour: Double?
            if let gain, let hours { gainPerHour = gain / hours }
            var gainPercent: Double?
            if let gain, materialsIfSold != 0 { gainPercent = gain / materialsIfSold }

            // Gain per hour, capped by the market: you can only earn as fast as your share of
            // the region's sales lets you sell. Share = sold per day ÷ (sellers at the hub + you).
            let bestSellers: Int = best.flatMap { books[Job(type: productID, hub: $0.hub)]?.int("sell_orders") } ?? 0
            let soldPerDayHere: Double = best?.check.double("sold_per_day") ?? 0
            let sharePerDay: Double = soldPerDayHere / Double(bestSellers + 1)
            var gainPerHourMarket: Double?
            var marketLimited = false
            if let gain, let hours, hours > 0 {
                let unitsBuilt = Double(max(unitsPerRun * totalRuns, 1))
                let buildPerHour = unitsBuilt / hours
                let sellPerHour = sharePerDay / 24
                let unitsPerHour = min(buildPerHour, sellPerHour)
                marketLimited = sellPerHour < buildPerHour
                gainPerHourMarket = gain / unitsBuilt * unitsPerHour
            }

            let check: JSONDict = best?.check ?? [:]
            let priceLive: Double? = check.double("live")
            let priceUsed: Double? = check.double("used")
            let fairPrice: Double? = check.double("fair")
            let priceStatus: String? = check.string("status")
            let priceTrend: String? = check.string("trend")
            let thinMarket: Bool = check.bool("thin")
            let daysToSell: Double? = check.double("days_to_sell")
            let spread: String? = best?.spread
            let saleFeeRate: Double? = best.map { (brokers[$0.hub] ?? 0) + salesTax }
            let sortedNeeds = needs.sorted { ($0.int("quantity") ?? 0) > ($1.int("quantity") ?? 0) }
            let isOwned: Bool = owned != nil
            let ownedIsCopy: Bool = owned?.isCopy ?? false
            let competition: Int = best?.competition ?? 0
            rows.append([
                "blueprint_type_id": blueprintID,
                "product_type_id": productID,
                "name": c.string("product_name") as Any,
                "group": c.string("group_name") as Any,
                "category": c.string("category_name") as Any,
                "tech": techName,
                "units_per_run": unitsPerRun,
                "owned": isOwned,
                "owned_is_copy": ownedIsCopy,
                "me": me,
                "te": te,
                "materials": sortedNeeds,
                "unpriced_materials": unpriced,
                "materials_if_sold": materialsIfSold,
                "job_fee": jobFee,
                "build_seconds": seconds,
                "best_hub": best?.hub as Any,
                "sell_price": best?.price as Any,
                "price_live": priceLive as Any,
                "price_used": priceUsed as Any,
                "fair_price": fairPrice as Any,
                "price_status": priceStatus as Any,
                "price_trend": priceTrend as Any,
                "thin_market": thinMarket,
                "days_to_sell": daysToSell as Any,
                "spread": spread as Any,
                // Share of the sale lost to broker fee + sales tax at the chosen hub.
                "sale_fee_rate": saleFeeRate as Any,
                "sale_check": best?.check as Any,
                "material_flags": materialFlags,
                "product_sale": best?.net as Any,
                "competition": competition,
                "gain": gain as Any,
                "gain_per_hour": gainPerHour as Any,
                "gain_per_hour_market": gainPerHourMarket as Any,
                "market_limited": marketLimited,
                "share_per_day": sharePerDay,
                "sellers": bestSellers,
                "gain_percent": gainPercent as Any,
            ])
        }

        // Market history for each item at the hub it would be sold in (parallel, cached 6 hours).
        let histories = try await concurrentMap(rows, limit: 16) { row -> (String?, JSONDict?) in
            let hubName = row.string("best_hub") ?? (sellHubs.count == 1 ? sellHubs[0] : nil)
            guard let hubName, let productID = row.int("product_type_id") else { return (hubName, nil) }
            return (hubName, try? await Market.hubHistory(hubName, productID, days: fairSettings.lookbackDays))
        }
        for index in rows.indices {
            let (hubName, history) = histories[index]
            rows[index]["sold_per_day"] = history?.double("sold_per_day") as Any
            rows[index]["average_price"] = history?.double("average_price") as Any
            rows[index]["history_hub"] = hubName as Any
        }

        // History: your watch stars, your own sales in the range, and how competition moved.
        var watched = Set<Int>()
        var mySales: [Int: (units: Int, value: Double)] = [:]
        if let cid = try? await EveAuth.shared.characterID() {
            watched = Set(await HistoryStore.shared.watchlist(cid))
            let sinceText = HistoryRange.since().map(ISODate.string)
            let sold = (try? await HistoryStore.shared.query("""
                SELECT type_id, SUM(quantity) AS units, SUM(quantity * unit_price) AS value FROM transactions
                WHERE character_id = ? AND is_buy = 0 AND (? IS NULL OR date >= ?) GROUP BY type_id
                """, [cid, sinceText, sinceText])) ?? []
            for s in sold {
                if let id = s.int("type_id") { mySales[id] = (s.int("units") ?? 0, s.double("value") ?? 0) }
            }
        }
        for index in rows.indices {
            let productID = rows[index].int("product_type_id") ?? 0
            rows[index]["watched"] = watched.contains(productID)
            rows[index]["my_sold_units"] = mySales[productID]?.units ?? 0
            rows[index]["my_sold_value"] = mySales[productID]?.value ?? 0.0
            let hubName = rows[index].string("best_hub") ?? sellHubs.first ?? ""
            if let trend = await HistoryStore.shared.competitionTrend(hub: hubName, typeID: productID) {
                rows[index]["trend"] = trend
            }
        }

        rows.sort { a, b in
            let ga = a.double("gain"), gb = b.double("gain")
            if (ga == nil) != (gb == nil) { return ga != nil }
            return -(ga ?? 0) < -(gb ?? 0)
        }

        // Oldest order book used = how current the prices are.
        var times: [Double] = []
        for t in productIDs {
            for h in sellHubs { if let f = try await Market.bookFetchedAt(h, t) { times.append(f) } }
        }
        for t in materialIDs {
            if let f = try await Market.bookFetchedAt(materialHub, t) { times.append(f) }
        }

        return [
            "prices_as_of": times.min() as Any,
            "material_hub": materialHub,
            "sell_hub": sellHub.isEmpty ? "best" : sellHub,
            "sales_tax": salesTax,
            "cost_index": costIndex,
            "price_band": fairSettings.band,
            "lookback_days": fairSettings.lookbackDays,
            "batch_runs": runs,
            "batch_totals": batchTotals,
            "price_gaps": priceGaps,
            "total": total,
            "limit": limit,
            "items": rows,
        ]
    }
}
