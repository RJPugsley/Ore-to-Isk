import Foundation

/// The app's endpoints (originally Backend/main.py), answered in-process.
/// BackendClient sends every request here and decodes the JSON into the app's models.
enum NativeBackend {

    // MARK: - Query parameters (FastAPI parsing)

    struct Query {
        let items: [String: String]

        init(_ queryItems: [URLQueryItem]) {
            var map: [String: String] = [:]
            for item in queryItems { map[item.name] = item.value ?? "" }
            items = map
        }

        func string(_ name: String, _ fallback: String) -> String { items[name] ?? fallback }

        func optionalInt(_ name: String) throws -> Int? {
            guard let text = items[name], !text.isEmpty else { return nil }
            guard let value = Int(text) else { throw RouteError(status: 422, detail: "\(name): value is not a valid integer") }
            return value
        }

        func int(_ name: String, _ fallback: Int) throws -> Int { try optionalInt(name) ?? fallback }

        func requiredInt(_ name: String) throws -> Int {
            guard let value = try optionalInt(name) else { throw RouteError(status: 422, detail: "\(name): field required") }
            return value
        }

        func optionalDouble(_ name: String) throws -> Double? {
            guard let text = items[name], !text.isEmpty else { return nil }
            guard let value = Double(text) else { throw RouteError(status: 422, detail: "\(name): value is not a valid number") }
            return value
        }

        func double(_ name: String, _ fallback: Double) throws -> Double { try optionalDouble(name) ?? fallback }

        func bool(_ name: String, _ fallback: Bool) throws -> Bool {
            guard let text = items[name]?.lowercased(), !text.isEmpty else { return fallback }
            if ["true", "1", "yes", "on", "t", "y"].contains(text) { return true }
            if ["false", "0", "no", "off", "f", "n"].contains(text) { return false }
            throw RouteError(status: 422, detail: "\(name): value could not be parsed to a boolean")
        }

        func search(_ name: String) throws -> String {
            let text = items[name] ?? ""
            guard text.count >= 2 else { throw RouteError(status: 422, detail: "\(name): ensure this value has at least 2 characters") }
            return text
        }
    }

    // MARK: - Entry point

    static func handle(method: String, path: String, query queryItems: [URLQueryItem], body: Data?) async throws -> Data {
        let route = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = Query(queryItems)
        do {
            guard method == "GET" else {
                await PageMemoStore.shared.clear()   // something changed – recalculate pages
                return try JSON.data(try await respond(method: method, route: route, query: query, body: body))
            }
            // A page you've just been on: reuse its result if nothing behind it has been updated.
            let memoKey = PageMemo.key(path: route, query: queryItems)
            if !PageMemo.bypasses(queryItems), let kept = await PageMemoStore.shared.reusable(memoKey) {
                return kept
            }
            let deps = PageDeps()
            let data = try await PageMemo.$deps.withValue(deps) {
                try JSON.data(try await respond(method: method, route: route, query: query, body: body))
            }
            await PageMemoStore.shared.keep(memoKey, data, deps)
            return data
        } catch let error as RouteError {
            throw BackendError.http(error.status, error.detail)
        } catch let error as DowntimeError {
            throw BackendError.http(503, error.localizedDescription)
        } catch {
            throw BackendError.http(500, error.localizedDescription)
        }
    }

    /// try / except Exception → HTTPException(status, str(exc))
    private static func wrap<T>(_ status: Int = 500, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as RouteError {
            throw error
        } catch let error as DowntimeError {
            throw RouteError(status: 503, detail: error.localizedDescription)
        } catch {
            throw RouteError(status: status, detail: error.localizedDescription)
        }
    }

    /// Background contract scan for Blueprint Copying's sales tracking (errors are ignored).
    /// Hourly: CCP's kills / jumps per system into history (Haul › Route, Watch List).
    /// Every 30 s while the app is open: note where you are, so trips (and regular routes) are counted.
    static func checkTravel() async {
        await Watch.checkTravel()
    }

    static func recordSystemActivity() async {
        await Routes.record()
        await Routes.loadStationNames()   // first time only: names for the station search
    }

    static func watchCopyContracts(hub: String) async {
        guard EveDowntime.isNow() == false,
              let regionID = try? await Market.hub(hub).int("region_id") else { return }
        _ = try? await Contracts.copyOffers(regionID: regionID)
    }

    private static func requireSDE() async throws {
        let state = await SDE.status()
        if state.string("state") != "ready" {
            let message = state.string("message") ?? ""
            throw RouteError(status: 503, detail: message.isEmpty ? "Static data is still being prepared." : message)
        }
    }

    /// {blueprint_type_id: best one you own} – BPO beats BPC, then ME, then TE.
    private static func ownedBlueprints(_ blueprints: [JSONDict]) -> [Int: (rank: [Int], info: JSONDict)] {
        var best: [Int: (rank: [Int], info: JSONDict)] = [:]
        for bp in blueprints {
            guard let typeID = bp.int("type_id") else { continue }
            let isCopy = bp.int("quantity") == -2
            let rank = [isCopy ? 0 : 1, bp.int("material_efficiency") ?? 0, bp.int("time_efficiency") ?? 0]
            // As before: replace when there's none yet or rank > current rank.
            if let current = best[typeID], !current.rank.lexicographicallyPrecedes(rank) { continue }
            best[typeID] = (rank, [
                "me": bp.int("material_efficiency") ?? 0,
                "te": bp.int("time_efficiency") ?? 0,
                "is_copy": isCopy,
                "runs": bp.int("runs") ?? 0,
            ])
        }
        return best
    }

    private static func ownedForBuildVsSell() async -> [Int: BuildVsSell.Owned] {
        guard let blueprints = try? await ESI.characterBlueprints() else { return [:] }
        return ownedBlueprints(blueprints).mapValues {
            BuildVsSell.Owned(me: $0.info.int("me") ?? 0, te: $0.info.int("te") ?? 0, isCopy: $0.info.bool("is_copy"))
        }
    }

    private static func refinerySettings(_ query: Query) throws -> Reprocessing.Settings {
        Reprocessing.Settings(
            oreYield: try query.optionalDouble("ore_yield"),
            oreSkill: query.string("ore_skill", "Coherent Ore Processing"),
            iceYield: try query.optionalDouble("ice_yield"),
            tax: try query.double("refinery_tax", 1.0)
        )
    }

    private static func permissionAware<T>(_ message: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as RouteError {
            throw error
        } catch {
            if let status = httpStatus(of: error), status == 401 || status == 403 {
                throw RouteError(status: 403, detail: message)
            }
            if error is DowntimeError { throw RouteError(status: 503, detail: error.localizedDescription) }
            throw RouteError(status: 500, detail: error.localizedDescription)
        }
    }

    // MARK: - Routes

    private static func respond(method: String, route: String, query: Query, body: Data?) async throws -> Any {
        switch (method, route) {
        case ("GET", ""):
            return ["application": "EVE ESI Connector", "status": "running", "login": "/auth/login", "health": "/health"]

        case ("GET", "health"):
            return ["status": "ok"]

        case ("GET", "character"):
            do {
                let characterID = try await EveAuth.shared.characterID()
                return ["character_id": characterID]
            } catch {
                throw RouteError(status: 401, detail: error.localizedDescription)
            }

        case ("GET", "esi/skills"):
            return try await wrap { try await ESI.characterSkills() }

        case ("GET", "esi/skillqueue"):
            return try await wrap { try await ESI.characterSkillqueue() }

        case ("GET", "esi/blueprints"):
            return try await wrap { try await ESI.characterBlueprints() }

        case ("GET", "esi/industry/jobs"):
            let includeCompleted = try query.bool("include_completed", false)
            return try await wrap { try await ESI.characterIndustryJobs(includeCompleted: includeCompleted) }

        case ("POST", "esi/locations"):
            let ids = (body.flatMap { try? JSON.parse($0) } as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            return try await wrap { await ESI.resolveLocations(ids) }

        // ---------------- Static data ----------------

        case ("GET", "sde/status"):
            return await SDE.status()

        case ("POST", "sde/update"):
            SDE.updateInBackground(force: try query.bool("force", false))
            return await SDE.status()

        case ("GET", "sde/skills"):
            try await requireSDE()
            return try SDE.skillCatalog()

        // ---------------- Industry calculator ----------------

        case ("GET", "industry/products"):
            let search = try query.search("search")
            try await requireSDE()
            return try SDE.searchProducts(search)

        case ("GET", "industry/products-in-group"):
            try await requireSDE()
            return try SDE.productsInGroup(category: query.string("category", ""), group: query.string("group", ""))

        case ("GET", "industry/my-products"):
            try await requireSDE()
            let owned = try await wrap { try await ESI.characterBlueprints() }
            var best = ownedBlueprints(owned)
            var counts: [Int: Int] = [:]
            for bp in owned { if let id = bp.int("type_id") { counts[id, default: 0] += 1 } }
            for (id, _) in best { best[id]?.info["count"] = counts[id] ?? 0 }
            var products = try SDE.productsForBlueprints(best.keys)
            for i in products.indices {
                guard let id = products[i].int("blueprint_type_id"), let info = best[id]?.info else { continue }
                products[i].merge(info) { _, new in new }
            }
            return products

        case ("GET", "industry/systems"):
            let search = try query.search("search")
            try await requireSDE()
            return try SDE.searchSystems(search)

        case ("GET", "industry/stock-locations"):
            return try await wrap { try await Market.stockLocations() }

        case ("GET", "industry/calculate"):
            try await requireSDE()
            let blueprintTypeID = try query.requiredInt("blueprint_type_id")
            let stock = try query.optionalInt("stock_location")
            let refinery = try query.optionalInt("refinery_location")
            let settings = try refinerySettings(query)
            let runs = try query.int("runs", 1)
            let me = try query.int("me", 0)
            let te = try query.int("te", 0)
            let systemID = try query.optionalInt("system_id")
            let rigME = try query.double("rig_me", 0)
            let rigTE = try query.double("rig_te", 0)
            let facilityTax = try query.optionalDouble("facility_tax")
            let useOwned = try query.bool("use_owned", true)
            do {
                return try await IndustryCalc.calculate(
                    blueprintTypeID: blueprintTypeID,
                    runs: runs, me: me, te: te,
                    systemID: systemID, structure: query.string("structure", "npc"),
                    rigME: rigME, rigTE: rigTE, facilityTax: facilityTax,
                    materialHub: query.string("material_hub", "Jita"),
                    materialPrice: query.string("material_price", "sell"),
                    useOwned: useOwned,
                    stockLocation: stock == 0 ? nil : stock,
                    refineryLocation: refinery == 0 ? nil : refinery,
                    refinery: settings
                )
            } catch let error as ValueError {
                throw RouteError(status: 404, detail: error.message)
            } catch let error as RouteError {
                throw error
            } catch {
                throw RouteError(status: 500, detail: error.localizedDescription)
            }

        // ---------------- Reference ----------------

        case ("GET", "reference/blueprint-categories"):
            try await requireSDE()
            let owned = await ownedForBuildVsSell()
            return try BuildVsSell.categories(owned.keys)

        case ("GET", "reference/build-vs-sell"):
            try await requireSDE()
            let ownedOnly = try query.bool("owned_only", false)
            let defaultME = try query.int("default_me", 0)
            let defaultTE = try query.int("default_te", 0)
            let systemID = try query.optionalInt("system_id")
            let rigME = try query.double("rig_me", 0)
            let rigTE = try query.double("rig_te", 0)
            let facilityTax = try query.optionalDouble("facility_tax")
            let limit = try query.int("limit", BuildVsSell.defaultLimit)
            let fresh = try query.bool("fresh", false)
            let priceBand: Double? = try query.optionalDouble("price_band").map { $0 / 100 }
            let lookbackDays: Int? = try query.optionalInt("lookback_days").map { max(7, min($0, 365)) }
            let batchRuns: Int? = try query.optionalInt("batch_runs").map { max(1, min($0, 100_000)) }
            let batchTotals = try query.bool("batch_totals", false)
            return try await wrap {
                let owned = await ownedForBuildVsSell()
                return try await BuildVsSell.compare(
                    category: query.string("category", ""), group: query.string("group", ""),
                    search: query.string("search", ""), ownedOnly: ownedOnly,
                    ownedBlueprints: owned, defaultME: defaultME, defaultTE: defaultTE,
                    systemID: systemID, structure: query.string("structure", "npc"),
                    rigME: rigME, rigTE: rigTE, facilityTax: facilityTax,
                    materialHub: query.string("material_hub", "Jita"),
                    sellHub: query.string("sell_hub", "best"),
                    limit: max(1, min(limit, 500)), fresh: fresh,
                    priceBand: priceBand, lookbackDays: lookbackDays, batchRuns: batchRuns,
                    batchTotals: batchTotals
                )
            }

        // ---------------- Haul ----------------
        case ("GET", "haul/ships"):
            try await requireSDE()
            return try await wrap { try await Hauling.ships() }

        case ("GET", "haul/plan"):
            try await requireSDE()
            let start = try query.int("start", 0)
            let excluded = Set(query.string("exclude", "").split(separator: ",").compactMap { Int($0) })
            let cargo = try query.double("cargo", 0)
            let warn = try query.double("warn_value", 0)
            return try await wrap {
                try await Hauling.plan(start: start, hub: query.string("hub", "Jita"), cargo: cargo,
                                       excluded: excluded, warnValue: warn)
            }

        case ("GET", "haul/route"):
            try await requireSDE()
            let from = try query.requiredInt("from")
            let to = try query.requiredInt("to")
            let avoid = query.string("avoid", "").split(separator: ",").compactMap { Int($0) }
            let maxExtra = try query.int("max_extra", 5)
            let via = query.string("via", "").split(separator: ",").compactMap { Int($0) }
            return try await wrap(502) {
                try await Routes.plan(from: from, to: to, via: via, mode: query.string("mode", "lowest_risk"),
                                      avoid: avoid, maxExtra: maxExtra, penalty: (try? query.int("penalty", 50)) ?? 50,
                                      avoidPodKills: (try? query.bool("avoid_pod_kills", false)) ?? false,
                                      preference: query.string("preference", "secure"),
                                      quick: (try? query.bool("quick", false)) ?? false)
            }

        // ---------------- In-game windows and waypoints (right-click menus) ----------------
        case ("POST", "ui/open"):
            let id = try query.requiredInt("id")
            let kind = query.string("kind", "info")
            guard await EveAuth.shared.grantedScopes().contains("esi-ui.open_window.v1") else {
                throw RouteError(status: 403, detail: "Log out and in again (Pilot tab) to let the app open windows in the game.")
            }
            try await wrap(502) {
                if kind == "market" {
                    _ = try await ESI.send("ui/openwindow/marketdetails/", params: ["type_id": String(id)], method: "POST")
                } else {
                    _ = try await ESI.send("ui/openwindow/information/", params: ["target_id": String(id)], method: "POST")
                }
            }
            return ["ok": true] as JSONDict

        case ("POST", "ui/waypoint"):
            let id = try query.requiredInt("id")
            let clear = (try? query.bool("clear", false)) ?? false
            guard await EveAuth.shared.grantedScopes().contains(Routes.waypointScope) else {
                throw RouteError(status: 403, detail: "Log out and in again (Pilot tab) to let the app set waypoints in the game.")
            }
            try await wrap(502) {
                _ = try await ESI.send("ui/autopilot/waypoint/", params: [
                    "add_to_beginning": "false", "clear_other_waypoints": clear ? "true" : "false", "destination_id": String(id),
                ], method: "POST")
            }
            return ["ok": true] as JSONDict

        case ("GET", "reference/blueprint-map"):
            // [[product type id, blueprint type id]] – which items can be built, for the right-click menus.
            try await requireSDE()
            let rows = try SDE.connect().query("""
                SELECT b.product_type_id, MIN(b.blueprint_type_id) AS blueprint_type_id FROM bp_manufacturing b
                JOIN types t ON t.type_id = b.blueprint_type_id WHERE t.published = 1 GROUP BY b.product_type_id
                """)
            return rows.compactMap { r -> [Int]? in
                guard let p = r.int("product_type_id"), let b = r.int("blueprint_type_id") else { return nil }
                return [p, b]
            }

        // ---------------- Watch List ----------------
        case ("GET", "watch/summary"):
            try await requireSDE()
            let quick = (try? query.bool("quick", false)) ?? false
            let fresh = (try? query.bool("fresh", false)) ?? false
            return try await wrap(502) { try await Watch.summary(quick: quick, fresh: fresh) }

        case ("POST", "watch/route"):
            let from = try query.requiredInt("from")
            let to = try query.requiredInt("to")
            await HistoryStore.shared.addWatchRoute(name: query.string("name", ""), from: from, to: to,
                                                    via: query.string("via", ""), avoid: query.string("avoid", ""),
                                                    kind: query.string("kind", "mine"))
            await TTLCache.shared.remove("watch_summary:true")
            await TTLCache.shared.remove("watch_summary:false")
            return ["ok": true] as JSONDict

        case ("POST", "watch/route/delete"):
            await HistoryStore.shared.deleteWatchRoute(try query.requiredInt("id"))
            await TTLCache.shared.remove("watch_summary:true")
            await TTLCache.shared.remove("watch_summary:false")
            return ["ok": true] as JSONDict

        case ("POST", "watch/route/rename"):
            await HistoryStore.shared.renameWatchRoute(try query.requiredInt("id"), name: query.string("name", ""))
            await TTLCache.shared.remove("watch_summary:true")
            await TTLCache.shared.remove("watch_summary:false")
            return ["ok": true] as JSONDict

        case ("GET", "haul/optimise"):
            try await requireSDE()
            let from = try query.requiredInt("from")
            let to = try query.requiredInt("to")
            let via = query.string("via", "").split(separator: ",").compactMap { Int($0) }
            let avoid = query.string("avoid", "").split(separator: ",").compactMap { Int($0) }
            return try await wrap(502) {
                try await Routes.optimiseStops(from: from, to: to, via: via, preference: query.string("preference", "secure"),
                                               penalty: (try? query.int("penalty", 50)) ?? 50, avoid: avoid)
            }

        case ("GET", "haul/here"):
            try await requireSDE()
            return try await wrap(502) { try await Routes.currentLocation() }

        case ("GET", "haul/places"):
            try await requireSDE()
            return await Routes.searchPlaces(query.string("q", ""))

        case ("POST", "haul/waypoints"):
            // path = every system in order; anchors = "position:location" for start, stops and end.
            let path = query.string("path", "").split(separator: ",").compactMap { Int($0) }
            let anchors: [(index: Int, location: Int)] = query.string("anchors", "").split(separator: ",").compactMap { pair in
                let parts = pair.split(separator: ":")
                guard parts.count == 2, let index = Int(parts[0]), let location = Int(parts[1]) else { return nil }
                return (index: index, location: location)
            }
            let destinationOnly = try query.bool("destination_only", false)
            let preference = query.string("preference", "secure")
            let sent: [Int] = try await wrap(502) {
                try await Routes.sendRoute(path: path, anchors: anchors, preference: preference, destinationOnly: destinationOnly,
                                           everySystem: (try? query.bool("every_system", false)) ?? false,
                                           penalty: (try? query.int("penalty", 50)) ?? 50,
                                           gameAvoid: query.string("game_avoid", "").split(separator: ",").compactMap { Int($0) },
                                           gameAvoidsPodKills: (try? query.bool("game_avoids_pod_kills", false)) ?? false)
            }
            return ["sent": sent.count] as JSONDict

        // ---------------- Market browser ----------------
        case ("GET", "market/groups"):
            try await requireSDE()
            return try MarketBrowser.groups()

        case ("GET", "market/types"):
            try await requireSDE()
            let group = try query.int("group", 0)
            return try MarketBrowser.types(group: group)

        case ("GET", "market/search"):
            try await requireSDE()
            let text = query.string("q", "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return [JSONDict]() }
            return try MarketBrowser.search(text)

        case ("GET", "market/names"):
            try await requireSDE()
            let ids = query.string("ids", "").split(separator: ",").compactMap { Int($0) }
            return try MarketBrowser.named(ids)

        case ("GET", "market/item"):
            try await requireSDE()
            let typeID = try query.int("type_id", 0)
            return try await wrap {
                try await MarketBrowser.item(typeID: typeID, scope: query.string("scope", "Jita"),
                                             referenceHub: query.string("reference_hub", "Jita"))
            }

        case ("GET", "reference/materials"):
            // {blueprint type id: [{name, quantity}]} – base materials for one run at ME 0.
            try await requireSDE()
            let ids = query.string("ids", "").split(separator: ",").compactMap { Int($0) }
            guard !ids.isEmpty else { return JSONDict() }
            let rows = try SDE.connect().query("""
                SELECT bm.blueprint_type_id, bm.quantity, t.name FROM bp_materials bm
                JOIN types t ON t.type_id = bm.material_type_id
                WHERE bm.blueprint_type_id IN (\(ids.map(String.init).joined(separator: ",")))
                ORDER BY bm.quantity DESC
                """)
            var result: [String: [JSONDict]] = [:]
            for r in rows {
                guard let id = r.int("blueprint_type_id") else { continue }
                result[String(id), default: []].append(["name": r.string("name") ?? "", "quantity": r.int("quantity") ?? 0])
            }
            return result

        case ("GET", "reference/suggest"):
            // Predictive search: names of buildable items matching what's typed.
            try await requireSDE()
            let q = query.string("q", "").trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return [String]() }
            // Stay inside the page's Category / Group so every suggestion actually shows up.
            var filters = ""
            var params: [Any?] = ["%\(q)%"]
            let category = query.string("category", "")
            let group = query.string("group", "")
            if !category.isEmpty { filters += " AND c.name = ?"; params.append(category) }
            if !group.isEmpty { filters += " AND g.name = ?"; params.append(group) }
            params.append("\(q)%")
            let rows = try SDE.connect().query("""
                SELECT DISTINCT p.name FROM bp_manufacturing m
                JOIN types p ON p.type_id = m.product_type_id
                JOIN types b ON b.type_id = m.blueprint_type_id
                JOIN groups g ON g.group_id = p.group_id
                JOIN categories c ON c.category_id = p.category_id
                WHERE p.published = 1 AND b.published = 1 AND p.name LIKE ?\(filters)
                ORDER BY (p.name LIKE ?) DESC, length(p.name), p.name
                LIMIT 8
                """, params)
            return rows.compactMap { $0.string("name") }

        case ("GET", "build/copying"):
            try await requireSDE()
            let systemID = try query.optionalInt("system_id")
            let facilityTax = try query.optionalDouble("facility_tax")
            let runsPerCopy = try query.optionalInt("runs_per_copy")
            let copies = try query.int("copies", 1)
            let ownedOnly = try query.bool("owned_only", false)
            return try await wrap {
                try await Copying.compare(
                    hub: query.string("hub", "Jita"), systemID: systemID,
                    structure: query.string("structure", "npc"), facilityTax: facilityTax,
                    runsPerCopy: runsPerCopy, copies: max(1, min(copies, 1000)),
                    category: query.string("category", ""), group: query.string("group", ""),
                    search: query.string("search", ""), ownedOnly: ownedOnly)
            }

        case ("GET", "reference/blueprint-payback"):
            try await requireSDE()
            let hideOwned = try query.bool("hide_owned", true)
            let assumeME = try query.int("assume_me", 0)
            let systemID = try query.optionalInt("system_id")
            let rigME = try query.double("rig_me", 0)
            let rigTE = try query.double("rig_te", 0)
            let facilityTax = try query.optionalDouble("facility_tax")
            let limit = try query.int("limit", BuildVsSell.defaultLimit)
            let fresh = try query.bool("fresh", false)
            return try await wrap {
                let owned = await ownedForBuildVsSell()
                return try await BlueprintPayback.compare(
                    category: query.string("category", ""), group: query.string("group", ""),
                    search: query.string("search", ""), ownedBlueprints: owned, hideOwned: hideOwned,
                    assumeME: assumeME, systemID: systemID, structure: query.string("structure", "npc"),
                    rigME: rigME, rigTE: rigTE, facilityTax: facilityTax,
                    materialHub: query.string("material_hub", "Jita"),
                    sellHub: query.string("sell_hub", "best"),
                    buyHub: query.string("buy_hub", "Jita"),
                    limit: max(1, min(limit, 500)), fresh: fresh)
            }

        // ---------------- Character ----------------

        case ("GET", "character/summary"):
            return try await wrap { try await CharacterSummaryEngine.summary() }

        case ("GET", "finances/summary"):
            let oreHub = query.string("ore_hub", "Jita")
            return try await permissionAware("Missing permission – use Character → Login.") {
                try await Finances.summary(oreHub: oreHub)
            }

        case ("GET", "market/my-orders"):
            let fresh = try query.bool("fresh", false)
            return try await permissionAware("Missing market orders permission – use Character → Login.") {
                try await MarketOrders.summary(fresh: fresh)
            }

        case ("GET", "dashboard/wallet"):
            let days = try query.int("days", 7)
            return try await permissionAware("No wallet permission – log in again to grant it.") {
                try await Wallet.summary(days: max(1, min(days, 30)))
            }

        // ---------------- Reprocessing / market ----------------

        case ("GET", "reprocessing/ores"):
            try await requireSDE()
            let oreYield = try query.optionalDouble("ore_yield")
            let iceYield = try query.optionalDouble("ice_yield")
            var settings: Reprocessing.Settings?
            if oreYield != nil || iceYield != nil { settings = try refinerySettings(query) }
            return try await wrap { try await Reprocessing.oreCatalog(settings) }

        case ("GET", "reprocessing/summary"):
            try await requireSDE()
            let locationID = try query.requiredInt("location_id")
            let settings = try refinerySettings(query)
            return try await wrap {
                try await Reprocessing.summary(locationID, settings,
                                               hub: query.string("hub", "Jita"),
                                               price: query.string("price", "buy"))
            }

        case ("GET", "reprocess-or-sell/summary"):
            try await requireSDE()
            let settings = try refinerySettings(query)
            let locationID = try query.int("location_id", 0)
            let refineryID = try query.int("refinery_id", 0)
            let at = query.string("at", "here")
            let sellHub = query.string("sell_hub", "Jita")
            let price = query.string("price", "buy")
            return try await permissionAware("Missing assets permission – log in again to grant it.") {
                try await ReprocessOrSell.summary(locationID: locationID, at: at, sellHub: sellHub, price: price,
                                                  refineryID: refineryID, settings: settings)
            }

        case ("GET", "reprocess-or-sell/item"):
            try await requireSDE()
            let settings = try refinerySettings(query)
            var typeID = try query.int("type_id", 0)
            if typeID == 0, let found = try ReprocessOrSell.typeID(named: query.string("name", "")) { typeID = found }
            guard typeID != 0 else { throw RouteError(status: 404, detail: "No item by that name reprocesses into anything.") }
            let quantity = try query.int("quantity", 1)
            let locationID = try query.int("location_id", 0)
            let refineryID = try query.int("refinery_id", 0)
            let at = query.string("at", "here")
            let sellHub = query.string("sell_hub", "Jita")
            let price = query.string("price", "buy")
            return try await wrap {
                try await ReprocessOrSell.item(typeID: typeID, quantity: quantity, locationID: locationID, at: at,
                                               sellHub: sellHub, price: price, refineryID: refineryID, settings: settings)
            }

        case ("GET", "reprocess-or-sell/suggest"):
            try await requireSDE()
            return try ReprocessOrSell.suggest(query.string("q", ""))

        case ("GET", "market/hubs"):
            return try await wrap { try await Market.hubs() }

        // ---------------- Mining ----------------

        case ("GET", "mining/ledger"):
            try await requireSDE()
            let hub = query.string("hub", "Jita")
            return try await wrap { try await Mining.ledger(hub: hub) }

        case ("GET", "build/plan"):
            try await requireSDE()
            let items = Mining.parseItems(query.string("items", ""))
            let rigME = try query.double("rig_me", 0)
            let subtract = try query.bool("subtract_stock", true)
            let stock = try query.optionalInt("stock_location")
            let refinery = try query.optionalInt("refinery_location")
            var bands = Set(query.string("spaces", "").split(separator: ",").map { String($0) })
            if bands.isEmpty { bands = try query.bool("highsec_only", true) ? ["High"] : ["High", "Low", "Null"] }
            let settings = try refinerySettings(query)
            let breakDown = try query.bool("break_down", true)
            let systemID = try query.optionalInt("system_id")
            let facilityTax = try query.optionalDouble("facility_tax")
            let useElsewhere = try query.bool("use_elsewhere", true)
            return try await wrap {
                try await Mining.buildPlan(items: items, structure: query.string("structure", "npc"), rigME: rigME,
                                      subtractStock: subtract, stockLocation: stock == 0 ? nil : stock,
                                      refineryLocation: refinery == 0 ? nil : refinery, settings: settings,
                                      bands: bands, hub: query.string("hub", "Jita"), breakDown: breakDown,
                                      systemID: systemID, facilityTax: facilityTax,
                                      sellHub: query.string("sell_hub", "best"), useElsewhere: useElsewhere)
            }

        // ---------------- History ----------------

        case ("GET", "history/sync"):
            let force = try query.bool("force", false)
            await HistoryStore.shared.sync(force: force)
            await StockOrigin.ensureBaseline()   // stock-origin tracking starts on the first sync
            let errors = await HistoryStore.shared.lastErrors
            return ["errors": errors]

        case ("GET", "history/track-record"):
            try await requireSDE()
            let productID = try query.requiredInt("product_type_id")
            return try await wrap {
                await HistoryStore.shared.sync()
                let all = try await HistoryReports.trackRecord()
                return all[productID] ?? [
                    "product_type_id": productID, "jobs": 0, "built_units": 0, "build_cost": 0.0,
                    "sold_units": 0, "untracked_sold": 0, "revenue": 0.0, "fees": 0.0, "fee_rate": 0.0,
                    "cost_of_sold": 0.0, "profit": 0.0, "in_stock": 0, "in_stock_cost": 0.0,
                    "range_label": HistoryRange.label(HistoryRange.days),
                ] as JSONDict
            }

        case ("GET", "history/order-results"):
            try await requireSDE()
            return try await wrap { try await HistoryReports.orderResults() }

        case ("GET", "history/jobs"):
            try await requireSDE()
            return try await wrap { try await HistoryReports.completedJobs() }

        case ("GET", "history/net-worth"):
            return try await wrap { try await HistoryReports.netWorthHistory() }

        case ("GET", "history/watchlist"):
            return try await wrap {
                let cid = try await EveAuth.shared.characterID()
                return await HistoryStore.shared.watchlist(cid)
            }

        case ("POST", "history/watch"):
            let typeID = try query.requiredInt("type_id")
            let on = try query.bool("on", true)
            return try await wrap {
                let cid = try await EveAuth.shared.characterID()
                try await HistoryStore.shared.setWatch(cid, typeID: typeID, on: on)
                return ["type_id": typeID, "watched": on] as JSONDict
            }

        default:
            throw RouteError(status: 404, detail: "Not Found")
        }
    }
}

extension NativeBackend {
    /// Forget character-specific caches (after logging in / out or switching engine).
    static func resetCaches() async {
        await ESIState.shared.reset()
        await TTLCache.shared.removeAll()
        await PageMemoStore.shared.clear()
    }

    /// What main.py's lifespan did on start-up: refresh CCP static data in the background.
    static func startup() {
        SDE.updateInBackground()
    }
}
