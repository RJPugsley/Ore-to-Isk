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

        let names = try SDE.typeNames(orders.compactMap { $0.int("type_id") })
        var places: [Int: String] = [:]
        for loc in Set(orders.compactMap { $0.int("location_id") }) {
            places[loc] = await ESI.placeName(loc)
        }

        let now = Date()
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
            rows.append([
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
            ])
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
            "escrow": buys.reduce(0.0) { $0 + ($1.double("escrow") ?? 0) },
            "beaten_count": rows.filter { $0.bool("beaten") }.count,
            "orders": rows,
        ]
    }
}
