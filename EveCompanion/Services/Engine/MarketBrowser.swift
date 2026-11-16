import Foundation

/// Sell › Market: browse the market like in game – the market tree, every order for an item,
/// its price history, and the app's own checks on top.
enum MarketBrowser {
    // MARK: Tree and items

    /// Every market group: {market_group_id, parent_group_id, name, has_types}.
    static func groups() throws -> [JSONDict] {
        (try? SDE.connect().query("SELECT market_group_id, parent_group_id, name, has_types FROM market_groups ORDER BY name")) ?? []
    }

    /// Items in one market group, A–Z.
    static func types(group: Int) throws -> [JSONDict] {
        try SDE.connect().query("""
            SELECT t.type_id, t.name, t.market_group_id, g.name AS group_name FROM types t
            LEFT JOIN groups g ON g.group_id = t.group_id
            WHERE t.market_group_id = ? AND t.published = 1 ORDER BY t.name
            """, [group])
    }

    /// Items on the market matching the text (starts-with first), for search and suggestions.
    static func search(_ text: String, limit: Int = 150) throws -> [JSONDict] {
        try SDE.connect().query("""
            SELECT t.type_id, t.name, t.market_group_id, g.name AS group_name FROM types t
            LEFT JOIN groups g ON g.group_id = t.group_id
            WHERE t.market_group_id IS NOT NULL AND t.published = 1 AND t.name LIKE ?
            ORDER BY (t.name LIKE ?) DESC, length(t.name), t.name LIMIT ?
            """, ["%\(text)%", "\(text)%", limit])
    }

    /// Name and group for a list of items (the Watched list).
    static func named(_ ids: [Int]) throws -> [JSONDict] {
        guard !ids.isEmpty else { return [] }
        return try SDE.connect().query("""
            SELECT t.type_id, t.name, t.market_group_id, g.name AS group_name FROM types t
            LEFT JOIN groups g ON g.group_id = t.group_id
            WHERE t.type_id IN (\(ids.map(String.init).joined(separator: ","))) ORDER BY t.name
            """)
    }

    // MARK: One item

    /// Everything about one item. scope = a hub name (all orders in that hub's region)
    /// or "hubs" (only orders at the five trade-hub stations).
    static func item(typeID: Int, scope: String, referenceHub: String) async throws -> JSONDict {
        let db = try SDE.connect()
        let info = try db.query("""
            SELECT t.type_id, t.name, t.volume, t.packaged_volume, g.name AS group_name, c.name AS category_name
            FROM types t LEFT JOIN groups g ON g.group_id = t.group_id
            LEFT JOIN categories c ON c.category_id = t.category_id WHERE t.type_id = ?
            """, [typeID]).first ?? [:]

        // ---- Orders ----
        let hubs = try await Market.hubs()
        var regionOrders: [JSONDict] = []
        if scope == "hubs" {
            let hubStations = Set(hubs.compactMap { $0.int("station_id") })
            let regionIDs = Array(Set(hubs.compactMap { $0.int("region_id") }))
            let perRegion = try await concurrentMap(regionIDs, limit: 5) { region -> [JSONDict] in
                (try? await regionBook(region, typeID)) ?? []
            }
            regionOrders = perRegion.flatMap { $0 }.filter { hubStations.contains($0.int("location_id") ?? 0) }
        } else {
            let hub = try await Market.hub(scope)
            regionOrders = try await regionBook(hub.int("region_id") ?? 0, typeID)
        }

        // Names for NPC stations; player structures need docking rights, so they're labelled.
        let stationIDs = regionOrders.compactMap { $0.int("location_id") }.filter { $0 < 1_000_000_000_000 }
        let names = await ESI.universeNames(Array(Set(stationIDs)))
        var systems: [Int: JSONDict] = [:]
        let systemIDs = Array(Set(regionOrders.compactMap { $0.int("system_id") }))
        if !systemIDs.isEmpty {
            for r in try db.query("SELECT system_id, name, security, region_name FROM solar_systems WHERE system_id IN (\(systemIDs.map(String.init).joined(separator: ",")))") {
                if let id = r.int("system_id") { systems[id] = r }
            }
        }
        func row(_ order: JSONDict) -> JSONDict {
            let location = order.int("location_id") ?? 0
            let system = systems[order.int("system_id") ?? 0]
            let systemName = system?.string("name") ?? "?"
            let place: String = names[location] ?? (location >= 1_000_000_000_000 ? "Player structure · \(systemName)" : systemName)
            return [
                "order_id": order.int("order_id") ?? 0,
                "price": order.double("price") ?? 0,
                "volume_remain": order.int("volume_remain") ?? 0,
                "volume_total": order.int("volume_total") ?? 0,
                "min_volume": order.int("min_volume") ?? 1,
                "range": order.string("range") ?? "",
                "location": place,
                "location_id": location,
                "system_id": order.int("system_id") ?? 0,
                "system": systemName,
                "region": system?.string("region_name") ?? "",
                "security": system?.double("security") as Any,
                "issued": order.string("issued") as Any,
                "duration": order.int("duration") ?? 0,
            ]
        }
        let sells = regionOrders.filter { !$0.bool("is_buy_order") }
            .sorted { ($0.double("price") ?? 0) < ($1.double("price") ?? 0) }
        let buys = regionOrders.filter { $0.bool("is_buy_order") }
            .sorted { ($0.double("price") ?? 0) > ($1.double("price") ?? 0) }

        // ---- Price history (the reference hub's region, a year) ----
        let reference = scope == "hubs" ? referenceHub : scope
        let referenceInfo = try await Market.hub(reference)
        let history = (try? await historyRows(referenceInfo.int("region_id") ?? 0, typeID)) ?? []

        // ---- Every hub side by side ----
        let books = try await concurrentMap(hubs, limit: 5) { hub -> JSONDict in
            let name = hub.string("name") ?? ""
            let book = (try? await Market.hubBook(name, typeID)) ?? [:]
            return [
                "hub": name,
                "sell": book.double("sell") as Any,
                "buy": book.double("buy") as Any,
                "sell_volume": book.int("sell_volume") ?? 0,
                "buy_volume": book.int("buy_volume") ?? 0,
                "sell_orders": book.int("sell_orders") ?? 0,
                "buy_orders": book.int("buy_orders") ?? 0,
            ]
        }

        // ---- The app's checks at the reference hub ----
        let settings = FairPrice.Settings.current
        let referenceBook = (try? await Market.hubBook(reference, typeID)) ?? [:]
        let summary = try? await Market.hubHistory(reference, typeID, days: settings.lookbackDays)
        let live: Double? = FairPrice.sellDepthPrice(referenceBook, quantity: 1) ?? referenceBook.double("sell")
        let check = FairPrice.check(live: live, history: summary, quantity: 1, settings: settings)
        let trend: JSONDict? = await HistoryStore.shared.competitionTrend(hub: reference, typeID: typeID)

        let sellRows: [JSONDict] = sells.prefix(300).map(row)
        let buyRows: [JSONDict] = buys.prefix(300).map(row)
        let volume: Double = info.double("packaged_volume") ?? info.double("volume") ?? 0
        let spread: String? = FairPrice.spread(referenceBook)
        let soldPerDay: Double? = summary?.double("sold_per_day")
        let averagePrice: Double? = summary?.double("average_price")
        let sellUnits: Int = sells.reduce(0) { $0 + ($1.int("volume_remain") ?? 0) }
        let buyUnits: Int = buys.reduce(0) { $0 + ($1.int("volume_remain") ?? 0) }
        return [
            "type_id": typeID,
            "name": info.string("name") ?? String(typeID),
            "group": info.string("group_name") as Any,
            "category": info.string("category_name") as Any,
            "volume": volume,
            "scope": scope,
            "reference_hub": reference,
            "sell_orders": sellRows,
            "buy_orders": buyRows,
            "sell_order_count": sells.count,
            "buy_order_count": buys.count,
            "sell_units": sellUnits,
            "buy_units": buyUnits,
            "history": history,
            "hubs": books,
            "check": check,
            "spread": spread as Any,
            "sold_per_day": soldPerDay as Any,
            "average_price": averagePrice as Any,
            "competition_trend": trend as Any,
            "lookback_days": settings.lookbackDays,
        ]
    }

    /// Every order for one item in a region (cached 5 minutes, like the hub books).
    private static func regionBook(_ regionID: Int, _ typeID: Int) async throws -> [JSONDict] {
        try await cached("region_book:\(regionID):\(typeID)", ttl: 300) {
            asDicts(try await ESI.getAllPages("markets/\(regionID)/orders/",
                                              params: ["order_type": "all", "type_id": String(typeID)], auth: false))
        }
    }

    /// Daily history rows for the last year: {date, average, highest, lowest, volume, order_count}.
    private static func historyRows(_ regionID: Int, _ typeID: Int) async throws -> [JSONDict] {
        try await cached("history_rows:\(regionID):\(typeID)", ttl: 6 * 3600) {
            var rows = asDicts(try await ESI.get("markets/\(regionID)/history/",
                                                 params: ["type_id": String(typeID)], auth: false))
            rows.sort { ($0.string("date") ?? "") < ($1.string("date") ?? "") }
            return Array(rows.suffix(365))
        }
    }
}
