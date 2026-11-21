import Foundation

/// Originally `market_orders.py`: your active market orders, and whether anyone
/// has undercut (sell) or outbid (buy) you at the same station.
enum MarketOrders {
    static let bookTTL: TimeInterval = 300

    /// All public orders for one type in a region (cached 5 minutes).
    private static func stationBook(_ regionID: Int, _ typeID: Int, fresh: Bool) async throws -> [JSONDict] {
        let key = "region_book:\(regionID):\(typeID)"
        if fresh { await TTLCache.shared.remove(key) }
        return try await cached(key, ttl: bookTTL) {
            asDicts(try await ESI.getAllPages("markets/\(regionID)/orders/",
                                              params: ["order_type": "all", "type_id": String(typeID)], auth: false))
        }
    }

    private static func orderSlots() async throws -> Int {
        let levels = try await Market.skillLevels()
        func lvl(_ name: String) throws -> Int { try Reprocessing.level(levels, name) }
        let trade = try lvl("Trade")
        let retail = try lvl("Retail")
        let wholesale = try lvl("Wholesale")
        let tycoon = try lvl("Tycoon")
        return 5 + 4 * trade + 8 * retail + 16 * wholesale + 32 * tycoon
    }

    static func summary(fresh: Bool = false) async throws -> JSONDict {
        let cid = try await EveAuth.shared.characterID()
        let orders = asDicts(try await ESI.get("characters/\(cid)/orders/"))
        let mine = Set(orders.compactMap { $0.int("order_id") })

        struct Pair: Hashable { let region: Int; let type: Int }
        let pairs = Array(Set(orders.map { Pair(region: $0.int("region_id") ?? 0, type: $0.int("type_id") ?? 0) }))
        let fetched = try await concurrentMap(pairs, limit: 8) { try await stationBook($0.region, $0.type, fresh: fresh) }
        let books = Dictionary(uniqueKeysWithValues: zip(pairs, fetched))
        // Regional price history per item (cached 6 h) → fair price and sold per day.
        let fairSettings = FairPrice.Settings.current
        let historyList = try await concurrentMap(pairs, limit: 8) { pair -> JSONDict? in
            try? await Market.regionHistory(pair.region, pair.type, days: fairSettings.lookbackDays)
        }
        var histories: [Pair: JSONDict] = [:]
        for (pair, history) in zip(pairs, historyList) { if let history { histories[pair] = history } }

        let names = try SDE.typeNames(orders.compactMap { $0.int("type_id") })
        var places: [Int: String] = [:]
        for loc in Set(orders.compactMap { $0.int("location_id") }) {
            places[loc] = await ESI.placeName(loc)
        }

        let now = Date()
        // ---- What's left on a sell order is really worth (19 Nov 2026, user) ----
        // Sales tax on what's left, the broker fee paid when listing plus every relist (price change)
        // the app saw, and what the items cost you (built at build cost / bought at price paid –
        // the same stock pool as Manufacturing's Track Record; mined or looted = no ISK cost).
        let levels = (try? await Market.skillLevels()) ?? [:]
        let standingMap = (try? await Market.standings()) ?? [:]
        let accounting = Double((try? IndustryCalc.skillLevel(levels, "Accounting")) ?? 0)
        let salesTax = 0.075 * (1 - 0.11 * accounting)
        let brokerRelations = Double((try? IndustryCalc.skillLevel(levels, "Broker Relations")) ?? 0)
        let advancedBroker = Double((try? IndustryCalc.skillLevel(levels, "Advanced Broker Relations")) ?? 0)
        let relistDiscount = min(1, 0.5 + 0.06 * advancedBroker)
        let pool = (try? await HistoryReports.boughtStock()) ?? [:]
        let hubList = (try? await Market.hubs()) ?? []

        /// Broker fee rate where the order sits. NPC station: skills + standings with its owner.
        /// Player structure: set by its owner, which apps can't read – estimated without standings.
        func brokerRate(_ location: Int) async -> (rate: Double, estimated: Bool) {
            guard ESI.isStation(location) else { return (max(0.01, 0.03 - 0.003 * brokerRelations), true) }
            var info: JSONDict? = hubList.first { $0.int("station_id") == location }
            if info == nil {
                info = try? await cached("station_owner_\(location)", ttl: 86_400) { () async throws -> JSONDict in
                    guard let station = try await ESI.get("universe/stations/\(location)/", auth: false) as? JSONDict else { return [:] }
                    let corp = station.int("owner")
                    var faction: Int?
                    if let corp { faction = (try? await ESI.get("corporations/\(corp)/", auth: false) as? JSONDict)?.int("faction_id") }
                    return ["owner_corporation_id": corp as Any, "owner_faction_id": faction as Any]
                }
            }
            guard let info, let rate = try? IndustryCalc.brokerFee(levels, info, standingMap) else {
                return (max(0.01, 0.03 - 0.003 * brokerRelations), true)
            }
            return (rate, false)
        }

        var rows: [JSONDict] = []
        for o in orders {
            let isBuy = o.bool("is_buy_order")
            let price = o.double("price") ?? 0
            let pair = Pair(region: o.int("region_id") ?? 0, type: o.int("type_id") ?? 0)
            let others = (books[pair] ?? []).filter { b in
                !mine.contains(b.int("order_id") ?? -1)
                    && b.int("location_id") == o.int("location_id")
                    && b.bool("is_buy_order") == isBuy
            }
            let bestOther: Double?
            let beaten: Bool
            if isBuy {
                bestOther = others.compactMap { $0.double("price") }.max()
                beaten = bestOther.map { $0 > price } ?? false
            } else {
                bestOther = others.compactMap { $0.double("price") }.min()
                beaten = bestOther.map { $0 < price } ?? false
            }
            let competingUnits = others.reduce(0) { $0 + ($1.int("volume_remain") ?? 0) }

            let issued = ISODate.parse(o.string("issued")) ?? now
            let expires = issued.addingTimeInterval(Double(o.int("duration") ?? 90) * 86400)
            let typeID = o.int("type_id") ?? 0
            let volumeRemain = o.int("volume_remain") ?? 0
            let valueLeft: Double = price * Double(volumeRemain)
            let name: String = names[typeID] ?? String(typeID)
            let station: String? = o.int("location_id").flatMap { places[$0] }
            var money: JSONDict = [:]
            if !isBuy {
                let total = max(1, o.int("volume_total") ?? 1)
                let remain = Double(volumeRemain)
                let location = o.int("location_id") ?? 0
                let broker = await brokerRate(location)
                // Prices this order has had, oldest first (the app's checks), ending with today's.
                var prices: [Double] = []
                if let orderID = o.int("order_id") {
                    let checks = (try? await HistoryStore.shared.query(
                        "SELECT price FROM order_checks WHERE character_id = ? AND order_id = ? ORDER BY time", [cid, orderID])) ?? []
                    for c in checks {
                        if let p = c.double("price"), p != prices.last { prices.append(p) }
                    }
                }
                if prices.last != price { prices.append(price) }
                let listedAt = prices.first ?? price
                let listingFee = max(100, broker.rate * listedAt * Double(total))
                var relistFees = 0.0
                var relists = 0
                if prices.count > 1 {
                    for i in 1..<prices.count {
                        let old = prices[i - 1], new = prices[i]
                        relists += 1
                        relistFees += (1 - relistDiscount) * broker.rate * new * remain
                            + broker.rate * max(new - old, 0) * remain
                    }
                }
                let feesPaid = listingFee + relistFees
                let feesShare = feesPaid * remain / Double(total)   // the part that belongs to what's left
                let taxLeft = price * remain * salesTax
                let stock = pool[typeID] ?? (0, 0)
                let costEach: Double? = stock.qty > 0 ? stock.cost / stock.qty : nil
                let costLeft = (costEach ?? 0) * remain
                let netLeft = price * remain - taxLeft - feesShare - costLeft
                money = [
                    "net_left": netLeft, "tax_left": taxLeft, "sales_tax_rate": salesTax,
                    "broker_rate": broker.rate, "broker_estimated": broker.estimated,
                    "listing_fee": listingFee, "relist_fees": relistFees, "relists": relists,
                    "fees_paid": feesPaid, "fees_share": feesShare,
                    "cost_each": costEach as Any, "cost_left": costLeft,
                ]
            }
            var row: JSONDict = [
                "order_id": o.value("order_id") as Any,
                "type_id": typeID,
                "name": name,
                "station": station as Any,
                "location_id": o.int("location_id") as Any,
                "is_buy": isBuy,
                "price": price,
                "volume_remain": volumeRemain,
                "volume_total": o.int("volume_total") ?? 0,
                "value_left": valueLeft,
                "escrow": o.double("escrow") ?? 0.0,
                "issued": o.string("issued") as Any,
                "expires": ISODate.string(expires),
                "best_other": bestOther as Any,
                "beaten": beaten,
                "competing_units": competingUnits,
            ]
            row.merge(money) { _, new in new }
            // Fair price (the Market chart's green line) and how fast it sells in the region.
            if let history = histories[pair] {
                let ownCheck = FairPrice.check(live: price, history: history, quantity: max(volumeRemain, 1), settings: fairSettings)
                row["fair_price"] = ownCheck.double("fair") as Any
                row["fair_trend"] = ownCheck.string("trend") as Any
                row["sold_per_day"] = ownCheck.double("sold_per_day") as Any
                row["days_to_sell"] = ownCheck.double("days_to_sell") as Any
                if let bestOther {
                    let theirs = FairPrice.check(live: bestOther, history: history, quantity: 1, settings: fairSettings)
                    // A competitor far below what it normally sells for – probably a one-off dump.
                    if !isBuy, let fair = theirs.double("fair"), fair > 0, bestOther < fair * 0.85 {
                        row["other_below_fair"] = true
                    }
                }
            }
            rows.append(row)
        }

        rows.sort { a, b in
            let ba = a.bool("beaten"), bb = b.bool("beaten")
            if ba != bb { return ba }
            return (a.string("name") ?? "") < (b.string("name") ?? "")
        }
        await HistoryStore.shared.recordOrderChecks(cid, rows)
        let sells = rows.filter { !$0.bool("is_buy") }
        let buys = rows.filter { $0.bool("is_buy") }
        let slots = try? await orderSlots()
        return [
            "checked_at": ISODate.string(now),
            "order_slots": slots as Any,
            "sell_count": sells.count,
            "buy_count": buys.count,
            "sell_value": sells.reduce(0.0) { $0 + ($1.double("value_left") ?? 0) },
            "sell_net_value": sells.reduce(0.0) { $0 + ($1.double("net_left") ?? 0) },
            "escrow": buys.reduce(0.0) { $0 + ($1.double("escrow") ?? 0) },
            "beaten_count": rows.filter { $0.bool("beaten") }.count,
            "orders": rows,
        ]
    }
}
