import Foundation

/// Originally `market.py`: hubs, prices, order books, history, cost indices,
/// standings, skills and what you own where – with the same short-lived caches.
enum Market {
    /// Main NPC trade hubs: the station everyone trades at (order matters – the hub table shows them in this order).
    static let hubStations: [(String, Int)] = [
        ("Jita", 60003760),     // Jita IV - Moon 4 - Caldari Navy Assembly Plant
        ("Amarr", 60008494),    // Amarr VIII (Oris) - Emperor Family Academy
        ("Dodixie", 60011866),  // Dodixie IX - Moon 20 - Federation Navy Assembly Plant
        ("Rens", 60004588),     // Rens VI - Moon 8 - Brutor Tribe Treasury
        ("Hek", 60005686),      // Hek VIII - Moon 12 - Boundless Creation Factory
    ]

    // MARK: - Hubs

    private static func loadHub(_ name: String, _ stationID: Int) async throws -> JSONDict {
        guard let station = try await ESI.get("universe/stations/\(stationID)/", auth: false) as? JSONDict,
              let systemID = station.int("system_id"),
              let system = try await ESI.get("universe/systems/\(systemID)/", auth: false) as? JSONDict,
              let constellationID = system.int("constellation_id"),
              let constellation = try await ESI.get("universe/constellations/\(constellationID)/", auth: false) as? JSONDict
        else { throw ValueError("Couldn't load trade hub \(name)") }

        let ownerCorp = station.int("owner")
        var factionID: Int?
        if let ownerCorp {
            factionID = (try? await ESI.get("corporations/\(ownerCorp)/", auth: false) as? JSONDict)?.int("faction_id")
        }
        return [
            "name": name,
            "station_id": stationID,
            "station_name": station.string("name") ?? name,
            "system_id": systemID,
            "region_id": constellation.int("region_id") as Any,
            "owner_corporation_id": ownerCorp as Any,
            "owner_faction_id": factionID as Any,
        ]
    }

    static func hubs() async throws -> [JSONDict] {
        try await cached("hubs", ttl: 24 * 3600) {
            try await concurrentMap(hubStations, limit: 5) { try await loadHub($0.0, $0.1) }
        }
    }

    static func hub(_ name: String) async throws -> JSONDict {
        for h in try await hubs() where (h.string("name") ?? "").lowercased() == name.lowercased() {
            return h
        }
        throw ValueError("Unknown trade hub \(name)")
    }

    // MARK: - Prices

    /// CCP's adjusted prices (used for job installation cost).
    static func adjustedPrices() async throws -> [Int: Double] {
        try await cached("adjusted_prices", ttl: 3600) {
            var result: [Int: Double] = [:]
            for r in asDicts(try await ESI.get("markets/prices/", auth: false)) {
                if let id = r.int("type_id") { result[id] = r.double("adjusted_price") ?? 0.0 }
            }
            return result
        }
    }

    /// CCP's average prices – the game's "Est. price" (used for net worth).
    static func averagePrices() async throws -> [Int: Double] {
        try await cached("average_prices", ttl: 3600) {
            var result: [Int: Double] = [:]
            for r in asDicts(try await ESI.get("markets/prices/", auth: false)) {
                guard let id = r.int("type_id") else { continue }
                // As before: average_price or adjusted_price or 0.0 (0 counts as missing)
                let average = r.double("average_price").flatMap { $0 != 0 ? $0 : nil }
                let adjusted = r.double("adjusted_price").flatMap { $0 != 0 ? $0 : nil }
                result[id] = average ?? adjusted ?? 0.0
            }
            return result
        }
    }

    /// {system_id: {activity: index}} from /industry/systems/.
    static func costIndices() async throws -> [Int: [String: Double]] {
        try await cached("cost_indices", ttl: 3600) {
            var result: [Int: [String: Double]] = [:]
            for r in asDicts(try await ESI.get("industry/systems/", auth: false)) {
                guard let id = r.int("solar_system_id") else { continue }
                var indices: [String: Double] = [:]
                for c in r.dicts("cost_indices") {
                    if let activity = c.string("activity") { indices[activity] = c.double("cost_index") ?? 0 }
                }
                result[id] = indices
            }
            return result
        }
    }

    /// Best sell / buy at the hub station for one type.
    private static func loadHubBook(_ hubInfo: JSONDict, _ typeID: Int) async throws -> JSONDict {
        let regionID = hubInfo.int("region_id") ?? 0
        let stationID = hubInfo.int("station_id") ?? 0
        let orders = asDicts(try await ESI.getAllPages("markets/\(regionID)/orders/",
                                                       params: ["order_type": "all", "type_id": String(typeID)],
                                                       auth: false))
        let sells = orders.filter { !$0.bool("is_buy_order") && $0.int("location_id") == stationID }
        let buys = orders.filter { $0.bool("is_buy_order") && $0.int("location_id") == stationID }

        let bestSell = sells.compactMap { $0.double("price") }.min()
        let bestBuy = buys.compactMap { $0.double("price") }.max()
        func volume(_ list: [JSONDict]) -> Int { list.reduce(0) { $0 + ($1.int("volume_remain") ?? 0) } }
        let book: JSONDict = [
            "sell": bestSell as Any,
            "buy": bestBuy as Any,
            "sell_volume": volume(sells),
            "buy_volume": volume(buys),
            "sell_orders": sells.count,
            "buy_orders": buys.count,
            "sell_volume_at_best": volume(sells.filter { $0.double("price") == bestSell }),
            "buy_volume_at_best": volume(buys.filter { $0.double("price") == bestBuy }),
            // Every order at the station, best first, for depth pricing (FairPrice).
            "sell_ladder": ladder(sells, cheapestFirst: true),
            "buy_ladder": ladder(buys, cheapestFirst: false),
        ]
        // Competition history for the items you build, trade or watch.
        await HistoryStore.shared.recordBook(hub: hubInfo.string("name") ?? "", typeID: typeID, book: book)
        return book
    }

    /// [{p: price, v: units left, min: minimum units per sale}] sorted best price first.
    private static func ladder(_ orders: [JSONDict], cheapestFirst: Bool) -> [JSONDict] {
        let rows: [JSONDict] = orders.compactMap { order -> JSONDict? in
            guard let price = order.double("price") else { return nil }
            let units = order.int("volume_remain") ?? 0
            let minimum = order.int("min_volume") ?? 1
            return ["p": price, "v": units, "min": minimum]
        }
        return rows.sorted { a, b in
            let pa = a.double("p") ?? 0
            let pb = b.double("p") ?? 0
            return cheapestFirst ? pa < pb : pa > pb
        }
    }

    private static func bookKey(_ hubName: String, _ typeID: Int) -> String { "book:\(hubName):\(typeID)" }

    static func hubBook(_ hubName: String, _ typeID: Int) async throws -> JSONDict {
        let h = try await hub(hubName)
        let name = h.string("name") ?? hubName
        return try await cached(bookKey(name, typeID), ttl: 300) { try await loadHubBook(h, typeID) }
    }

    private static func loadHistory(_ regionID: Int, _ typeID: Int, _ days: Int) async -> JSONDict {
        var rows = asDicts((try? await ESI.get("markets/\(regionID)/history/",
                                               params: ["type_id": String(typeID)], auth: false)) ?? [Any]())
        rows.sort { ($0.string("date") ?? "") < ($1.string("date") ?? "") }
        rows = Array(rows.suffix(days))
        let volume = rows.reduce(0.0) { $0 + Double($1.int("volume") ?? 0) }
        let weighted = rows.reduce(0.0) { $0 + ($1.double("average") ?? 0) * Double($1.int("volume") ?? 0) }
        // Medians of the daily average price: one crazy day barely moves them (FairPrice).
        let lastWeek = Array(rows.suffix(7))
        let weekVolume = lastWeek.reduce(0.0) { $0 + Double($1.int("volume") ?? 0) }
        let averagePrice: Double? = volume > 0 ? weighted / volume : nil
        let medianAll: Double? = median(rows.compactMap { $0.double("average") })
        let medianWeek: Double? = median(lastWeek.compactMap { $0.double("average") })
        let typicalLow: Double? = median(rows.compactMap { $0.double("lowest") })
        let typicalHigh: Double? = median(rows.compactMap { $0.double("highest") })
        let soldPerDay: Double = volume / Double(max(days, 1))
        let soldPerDay7: Double = weekVolume / 7
        return [
            "days": rows.count,
            "sold_per_day": soldPerDay,
            "sold_per_day_7": soldPerDay7,
            "average_price": averagePrice as Any,
            "median_price": medianAll as Any,
            "median_7": medianWeek as Any,
            "typical_low": typicalLow as Any,
            "typical_high": typicalHigh as Any,
        ]
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Daily sales over the last `days` days in the hub's region – cached for 6 hours.
    static func hubHistory(_ hubName: String, _ typeID: Int, days: Int = 30) async throws -> JSONDict {
        let h = try await hub(hubName)
        let regionID = h.int("region_id") ?? 0
        return try await cached("history:\(regionID):\(typeID):\(days)", ttl: 6 * 3600) {
            await loadHistory(regionID, typeID, days)
        }
    }

    /// Price history for a type in any region (same cache as hubHistory).
    static func regionHistory(_ regionID: Int, _ typeID: Int, days: Int = 30) async throws -> JSONDict {
        try await cached("history:\(regionID):\(typeID):\(days)", ttl: 6 * 3600) {
            await loadHistory(regionID, typeID, days)
        }
    }

    /// When the cached order book for this hub/type was fetched (epoch seconds), or nil.
    static func bookFetchedAt(_ hubName: String, _ typeID: Int) async throws -> Double? {
        let name = try await hub(hubName).string("name") ?? hubName
        return await TTLCache.shared.fetchedAt(bookKey(name, typeID))?.timeIntervalSince1970
    }

    /// Drop cached order books so the next lookup fetches fresh orders from ESI.
    static func forgetBooks<H: Sequence, T: Sequence>(_ hubNames: H, _ typeIDs: T) async throws
        where H.Element == String, T.Element == Int {
        let types = Array(typeIDs)
        for h in hubNames {
            let name = try await hub(h).string("name") ?? h
            for t in types { await TTLCache.shared.remove(bookKey(name, t)) }
        }
    }

    /// Order book summaries for many types at one hub (parallel).
    static func hubBooks<S: Sequence>(_ hubName: String, _ typeIDs: S) async throws -> [Int: JSONDict] where S.Element == Int {
        let ids = Array(Set(typeIDs))
        let books = try await concurrentMap(ids, limit: 8) { try await hubBook(hubName, $0) }
        return Dictionary(uniqueKeysWithValues: zip(ids, books))
    }

    /// Like hubBooks, but one order book that EVE's servers won't give us (after retries)
    /// doesn't sink the whole page: it's left out and its type ID is returned in `failed`.
    static func hubBooksAllowingGaps<S: Sequence>(_ hubName: String, _ typeIDs: S) async throws
        -> (books: [Int: JSONDict], failed: [Int]) where S.Element == Int {
        let ids = Array(Set(typeIDs))
        let results = try await concurrentMap(ids, limit: 8) { id -> JSONDict? in
            try? await hubBook(hubName, id)
        }
        var books: [Int: JSONDict] = [:]
        var failed: [Int] = []
        for (id, book) in zip(ids, results) {
            if let book { books[id] = book } else { failed.append(id) }
        }
        return (books, failed)
    }

    static func allHubBooks(_ typeID: Int) async throws -> [String: JSONDict] {
        let names = try await hubs().compactMap { $0.string("name") }
        let books = try await concurrentMap(names, limit: 5) { try await hubBook($0, typeID) }
        return Dictionary(uniqueKeysWithValues: zip(names, books))
    }

    // MARK: - Character: standings, skills, assets

    /// Standings keyed "from_type:from_id".
    static func standingKey(_ fromType: String, _ fromID: Int?) -> String { "\(fromType):\(fromID.map(String.init) ?? "None")" }

    static func standings() async throws -> [String: Double] {
        try await cached("standings", ttl: 3600) {
            let cid = try await EveAuth.shared.characterID()
            var result: [String: Double] = [:]
            for r in asDicts(try await ESI.get("characters/\(cid)/standings/")) {
                result[standingKey(r.string("from_type") ?? "", r.int("from_id"))] = r.double("standing") ?? 0
            }
            return result
        }
    }

    /// {skill_type_id: active level}
    static func skillLevels() async throws -> [Int: Int] {
        try await cached("skills", ttl: 600) {
            let cid = try await EveAuth.shared.characterID()
            let data = try await ESI.get("characters/\(cid)/skills/") as? JSONDict
            var result: [Int: Int] = [:]
            for s in data?.dicts("skills") ?? [] {
                if let id = s.int("skill_id") { result[id] = s.int("active_skill_level") ?? 0 }
            }
            return result
        }
    }

    /// Station / structure an asset ultimately sits in (walks up through containers & ships).
    static func rootLocation(_ asset: JSONDict, _ byItem: [Int: JSONDict]) -> Int {
        var location = asset.int("location_id") ?? 0
        for _ in 0..<6 {
            guard let parent = byItem[location] else { return location }
            location = parent.int("location_id") ?? 0
        }
        return location
    }

    /// {type_id: quantity} you own – everywhere, or only at one station (incl. its containers).
    static func ownedQuantities(_ locationID: Int? = nil) async throws -> [Int: Int] {
        let byItem = try await ESI.getAssets().byItem
        var totals: [Int: Int] = [:]
        for a in byItem.values {
            if let locationID, locationID != 0, rootLocation(a, byItem) != locationID { continue }
            guard let typeID = a.int("type_id") else { continue }
            totals[typeID, default: 0] += a.int("quantity") ?? 1
        }
        return totals
    }

    /// Everything you own except at `excluding`: {type: {station / structure: quantity}}.
    static func ownedByLocation(excluding: Int?) async throws -> [Int: [Int: Int]] {
        let byItem = try await ESI.getAssets().byItem
        var result: [Int: [Int: Int]] = [:]
        for a in byItem.values {
            if ["Implant", "Skill", "SkillInTraining"].contains(a.string("location_flag") ?? "") { continue }
            let root = rootLocation(a, byItem)
            if let excluding, root == excluding { continue }
            guard let typeID = a.int("type_id") else { continue }
            result[typeID, default: [:]][root, default: 0] += a.int("quantity") ?? 1
        }
        return result
    }

    /// Stations / structures where you have assets, busiest first: [{location_id, name, items}].
    static func stockLocations() async throws -> [JSONDict] {
        let byItem = try await ESI.getAssets().byItem
        var counts: [Int: Int] = [:]
        for a in byItem.values {
            if ["Implant", "Skill", "SkillInTraining"].contains(a.string("location_flag") ?? "") { continue }
            counts[rootLocation(a, byItem), default: 0] += 1
        }
        let names = await ESI.resolveLocations(Array(counts.keys))
        let rows: [JSONDict] = counts.map { loc, n in
            [
                "location_id": loc,
                "name": ((names[String(loc)] as? JSONDict)?.string("name")) ?? String(loc),
                "items": n,
            ]
        }
        return rows.sorted { ($0.int("items") ?? 0) > ($1.int("items") ?? 0) }
    }
}
