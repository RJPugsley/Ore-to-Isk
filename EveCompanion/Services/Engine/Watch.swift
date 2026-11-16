import Foundation

/// Haul › Watch List: the routes you fly and the places you use, with the Route page's lights.
///
///  - Your routes: saved from the Route page ("Watch this route").
///  - Regular routes: learned – the app notes every dock-to-dock trip while it's open (EVE keeps no
///    travel history an app can read); a pair of places flown 10 times in the last 90 days (either
///    way round) becomes a regular route.
///  - Places: home, where you've mined, where your hangars, industry jobs and market orders are.
enum Watch {
    static let regularTrips = 10
    static let regularDays = 90

    // MARK: Trips (polled every 30 s by AppState while the app is open)

    /// Notes where you are; a dock somewhere other than where you last undocked = one trip.
    static func checkTravel() async {
        guard !EveDowntime.isNow(), let cid = try? await EveAuth.shared.characterID(),
              let here = try? await ESI.get("characters/\(cid)/location/") as? JSONDict else { return }
        let dock = here.int("station_id") ?? here.int("structure_id")
        if let structure = here.int("structure_id"), let system = here.int("solar_system_id") {
            if await HistoryStore.shared.structureRow(structure) == nil {
                let name = await ESI.placeName(structure)
                await HistoryStore.shared.saveStructure(structure, name: name.hasPrefix("Structure ") ? nil : name,
                                                        system: system, type: nil)
            }
        }
        let state = await HistoryStore.shared.travelState(cid)
        let lastDock = state?.int("last_dock")
        let undocked = (state?.int("undocked") ?? 0) == 1
        let now = Date().timeIntervalSince1970
        if let dock {
            if let lastDock, undocked, dock != lastDock {
                await HistoryStore.shared.addTrip(cid, from: lastDock, to: dock, started: state?.double("undocked_at"), ended: now)
            }
            if dock != lastDock || undocked {
                await HistoryStore.shared.setTravelState(cid, lastDock: dock, undocked: false, at: nil)
            }
        } else if lastDock != nil && !undocked {
            await HistoryStore.shared.setTravelState(cid, lastDock: lastDock, undocked: true, at: now)
        }
    }

    // MARK: Summary

    private struct Settings {
        var preference = "secure"
        var penalty = 50
        var avoidPodKills = false
        var avoid: [Int] = []
        var avoidText = ""

        /// The Route page's Autopilot settings (UserDefaults route.*).
        static var current: Settings {
            let d = UserDefaults.standard
            var s = Settings()
            s.preference = d.string(forKey: "route.autopilot") ?? "secure"
            if d.object(forKey: "route.penalty") != nil { s.penalty = d.integer(forKey: "route.penalty") }
            s.avoidPodKills = d.bool(forKey: "route.avoidPodKills")
            s.avoidText = d.string(forKey: "route.avoid") ?? ""
            s.avoid = Watch.ids(s.avoidText)
            return s
        }
    }

    /// "id|name,id|name" → ids
    static func ids(_ text: String) -> [Int] {
        text.split(separator: ",").compactMap { Int($0.split(separator: "|").first ?? "") }
    }

    /// Every watched route and place with its lights. quick = route shapes and CCP's figures only.
    static func summary(quick: Bool, fresh: Bool) async throws -> JSONDict {
        let key = "watch_summary:\(quick)"
        if fresh { await TTLCache.shared.remove(key) }
        return try await cached(key, ttl: 300) { () async throws -> JSONDict in
            try await buildSummary(quick: quick)
        }
    }

    private static func buildSummary(quick: Bool) async throws -> JSONDict {
        let cid = try await EveAuth.shared.characterID()
        let settings = Settings.current
        let now = Date().timeIntervalSince1970

        // ---- Routes: yours + regular ----
        struct Entry {
            var key: String
            var id: Int?
            var name: String?
            var kind: String          // mine · regular · pinned
            var trips: Int?
            var from: Int
            var to: Int
            var via: String
            var avoid: String
        }
        var entries: [Entry] = []
        for r in await HistoryStore.shared.watchRoutes() {
            guard let from = r.int("from_loc"), let to = r.int("to_loc") else { continue }
            entries.append(Entry(key: "w\(r.int("id") ?? 0)", id: r.int("id"), name: r.string("name"),
                                 kind: r.string("kind") ?? "mine", trips: nil, from: from, to: to,
                                 via: r.string("via") ?? "", avoid: r.string("avoid") ?? settings.avoidText))
        }
        let pairs = await HistoryStore.shared.tripPairs(cid, since: now - Double(regularDays) * 86400)
        var tripsByPair: [String: Int] = [:]
        for p in pairs {
            guard let a = p.int("a"), let b = p.int("b") else { continue }
            let n = p.int("trips") ?? 0
            tripsByPair["\(a)-\(b)"] = n
            guard n >= regularTrips else { continue }
            // Already watched (same places, or the same systems at each end, either way round)? Then it's not
            // added again – the watched route just gets its trip count.
            var match = entries.firstIndex(where: { Set([$0.from, $0.to]) == Set([a, b]) })
            if match == nil {
                let systemA = await Hauling.systemOf(a) ?? a
                let systemB = await Hauling.systemOf(b) ?? b
                let tripSystems: Set<Int> = [systemA, systemB]
                for (index, entry) in entries.enumerated() {
                    let watchedFrom = await Hauling.systemOf(entry.from) ?? entry.from
                    let watchedTo = await Hauling.systemOf(entry.to) ?? entry.to
                    if Set([watchedFrom, watchedTo]) == tripSystems { match = index; break }
                }
            }
            if let index = match {
                entries[index].trips = max(entries[index].trips ?? 0, n)
                continue
            }
            // Fly it the way you fly it most.
            let forward = p.int("forward") ?? 0
            let (from, to) = forward * 2 >= n ? (a, b) : (b, a)
            entries.append(Entry(key: "r\(a)-\(b)", id: nil, name: nil, kind: "regular", trips: n,
                                 from: from, to: to, via: "", avoid: settings.avoidText))
        }
        for i in entries.indices where entries[i].trips == nil {
            let pairKey = "\(min(entries[i].from, entries[i].to))-\(max(entries[i].from, entries[i].to))"
            entries[i].trips = tripsByPair[pairKey]
        }

        var routes: [JSONDict] = []
        for entry in entries {
            let fromPlace = await Routes.describe(entry.from)
            let toPlace = await Routes.describe(entry.to)
            let viaIDs = ids(entry.via)
            var route: JSONDict = [
                "key": entry.key,
                "id": entry.id.map { $0 as Any } ?? NSNull(),
                "kind": entry.kind,
                "trips": entry.trips.map { $0 as Any } ?? NSNull(),
                "from_loc": entry.from,
                "to_loc": entry.to,
                "from_name": fromPlace.string("name") ?? "",
                "to_name": toPlace.string("name") ?? "",
                "name": entry.name ?? "\(short(fromPlace)) → \(short(toPlace))",
                "via": entry.via,
                "avoid": entry.avoid,
            ]
            do {
                let plan = try await Routes.plan(from: entry.from, to: entry.to, via: viaIDs, mode: "game",
                                                 avoid: ids(entry.avoid), maxExtra: 0, penalty: settings.penalty,
                                                 avoidPodKills: settings.avoidPodKills, preference: settings.preference,
                                                 quick: quick)
                let rows = (plan["systems"] as? [JSONDict]) ?? []
                let worstRow = rows.first { $0.string("light") == "red" } ?? rows.first { $0.string("light") == "amber" }
                func sum(_ k: String) -> Int { rows.reduce(0) { $0 + ($1.int(k) ?? 0) } }
                route["ok"] = true
                route["worst"] = plan.string("worst") ?? "green"
                route["worst_system"] = worstRow?.string("name").map { $0 as Any } ?? NSNull()
                route["worst_reason"] = (worstRow?["reasons"] as? [String])?.first.map { $0 as Any } ?? NSNull()
                route["jumps"] = plan.int("jumps") ?? 0
                route["ganks_week"] = sum("ganks_week")
                route["hauler_ganks_week"] = sum("hauler_ganks_week")
                route["hauler_ganks_day"] = sum("hauler_ganks_day_counting")
                route["kills_last_hour"] = plan.int("kills_last_hour") ?? 0
                route["systems"] = rows
            } catch {
                route["ok"] = false
                route["error"] = error.localizedDescription
                route["worst"] = "pending"
                route["jumps"] = 0
                route["ganks_week"] = 0
                route["hauler_ganks_week"] = 0
                route["hauler_ganks_day"] = 0
                route["kills_last_hour"] = 0
                route["systems"] = [JSONDict]()
            }
            routes.append(route)
        }

        // ---- Places ----
        let since30 = ISODate.day(Date().addingTimeInterval(-30 * 86400))
        let since90 = ISODate.day(Date().addingTimeInterval(-90 * 86400))
        var why: [Int: [String]] = [:]      // system → reasons it's watched
        var docks: [Int: Set<Int>] = [:]    // system → stations / structures you use there
        func note(_ system: Int?, _ reason: String, dock: Int? = nil) {
            guard let system, system != 0 else { return }
            if !(why[system] ?? []).contains(reason) { why[system, default: []].append(reason) }
            if let dock { docks[system, default: []].insert(dock) }
        }
        if let clones = try? await cached("watch_home:\(cid)", ttl: 3600, { () async throws -> Any in
            try await ESI.get("characters/\(cid)/clones/")
        }) as? JSONDict, let home = clones.dict("home_location")?.int("location_id") {
            note(await Hauling.systemOf(home), "Home", dock: home)
        }
        for system in await HistoryStore.shared.minedSystems(cid, since: since30) { note(system, "Mined here") }
        for place in ((try? await Market.stockLocations()) ?? []).prefix(6) {
            guard let location = place.int("location_id") else { continue }
            note(await Hauling.systemOf(location), "Your hangar", dock: ESI.isSystem(location) ? nil : location)
        }
        for facility in await HistoryStore.shared.jobFacilities(cid, since: since30) {
            note(await Hauling.systemOf(facility), "Industry job", dock: facility)
        }
        for location in await HistoryStore.shared.orderLocations(cid, since: since90) {
            note(await Hauling.systemOf(location), "Market order", dock: location)
        }

        // How much you use each system: docks there (trips, 90 days) + days mined there (90 days).
        var visits: [Int: Int] = [:]
        for (location, n) in await HistoryStore.shared.dockVisits(cid, since: now - Double(regularDays) * 86400) {
            if let system = await Hauling.systemOf(location) {
                visits[system, default: 0] += n
                if why[system] == nil { note(system, "Docked here", dock: ESI.isSystem(location) ? nil : location) }
            }
        }
        for (system, days) in await HistoryStore.shared.miningDays(cid, since: since90) { visits[system, default: 0] += days }

        var places: [JSONDict] = []
        for (system, reasons) in why {
            let dockSet = docks[system] ?? []
            let dock: Int? = dockSet.count == 1 ? dockSet.first : nil   // one place you use there → judge its undock
            let rows = await Routes.evaluate([system], startDock: dock, endDock: dock, quick: quick)
            guard let row = rows.first else { continue }
            var dockName: Any = NSNull()
            if let dock, let name = (await Routes.describe(dock)).string("name") { dockName = name }
            places.append([
                "key": "p\(system)",
                "system_id": system,
                "name": row.string("name") ?? String(system),
                "dock_name": dockName,
                "why": reasons,
                "visits": visits[system] ?? 0,
                "row": row,
            ])
        }

        let order = ["red": 3, "amber": 2, "pending": 1, "green": 0]
        func rank(_ light: String?) -> Int { order[light ?? "green"] ?? 0 }
        routes.sort { rank($0.string("worst")) > rank($1.string("worst")) }
        // Most used first (Home first among equals).
        places.sort {
            let a = $0.int("visits") ?? 0, b = $1.int("visits") ?? 0
            if a != b { return a > b }
            return (($0["why"] as? [String]) ?? []).contains("Home")
        }
        return [
            "routes": routes,
            "places": places,
            "trips_seen": await HistoryStore.shared.tripCount(cid),
            "regular_trips": regularTrips,
            "regular_days": regularDays,
            "checked_at": now,
        ]
    }

    /// "Jita IV - Moon 4 - Caldari Navy Assembly Plant" → "Jita"; a system's own name as is.
    private static func short(_ place: JSONDict) -> String {
        let system = place.string("system_name") ?? ""
        return system.isEmpty ? (place.string("name") ?? "?") : system
    }
}
