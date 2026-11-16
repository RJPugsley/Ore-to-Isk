import Foundation

/// Haul › Route: a route jump by jump with security, traffic, kills and ganks, a traffic light per
/// system, three ways to route (shortest / safest / lowest risk), an avoid list and "send to game".
///
/// Data:
///  - CCP's hourly kills and jumps per system (universe/system_kills, universe/system_jumps) –
///    saved every hour into history.sqlite, so 24 h / 7 d totals build up from the app's own records.
///  - zKillboard: every killmail in a system over the last 7 days (from day one). The newest ones are
///    read from ESI once (and kept) to see the victim's ship and whether CONCORD was on it = a gank.
enum Routes {
    static let concordCorporation = 1000125
    static let haulerGroups: Set<String> = [
        "Industrial", "Deep Space Transport", "Blockade Runner", "Freighter", "Jump Freighter",
        "Industrial Command Ship",
    ]

    // MARK: Hourly activity

    /// Read CCP's last hour of kills and jumps for every system and keep it. Cached 10 minutes.
    /// {system_id: {ship_kills, pod_kills, npc_kills, jumps}}
    static func liveActivity() async throws -> [Int: JSONDict] {
        try await cached("system_activity", ttl: 600) { () async throws -> [Int: JSONDict] in
            let (killsData, killsResponse) = try await ESI.send("universe/system_kills/", auth: false)
            let (jumpsData, _) = try await ESI.send("universe/system_jumps/", auth: false)
            var rows: [Int: (ship: Int, pod: Int, npc: Int, jumps: Int)] = [:]
            let killsJSON = try JSON.parse(killsData)
            let jumpsJSON = try JSON.parse(jumpsData)
            for r in asDicts(killsJSON) {
                guard let id = r.int("system_id") else { continue }
                rows[id] = (r.int("ship_kills") ?? 0, r.int("pod_kills") ?? 0, r.int("npc_kills") ?? 0, rows[id]?.jumps ?? 0)
            }
            for r in asDicts(jumpsJSON) {
                guard let id = r.int("system_id") else { continue }
                let old = rows[id] ?? (0, 0, 0, 0)
                rows[id] = (old.ship, old.pod, old.npc, r.int("ship_jumps") ?? 0)
            }
            // The hour CCP's figures cover: Last-Modified, rounded down to the hour.
            let modified = httpDate(killsResponse.value(forHTTPHeaderField: "Last-Modified")) ?? Date().addingTimeInterval(-3600)
            let hour = (modified.timeIntervalSince1970 / 3600).rounded(.down) * 3600
            await HistoryStore.shared.saveSystemActivity(hour: hour, rows)
            var result: [Int: JSONDict] = [:]
            for (id, r) in rows {
                result[id] = ["ship_kills": r.ship, "pod_kills": r.pod, "npc_kills": r.npc, "jumps": r.jumps]
            }
            return result
        }
    }

    /// Called every hour by the app, so the history keeps building while it's open.
    static func record() async {
        guard !EveDowntime.isNow() else { return }
        _ = try? await liveActivity()
    }

    private static func httpDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    // MARK: Kills and ganks (zKillboard + ESI killmails)

    /// One system from zKillboard: {kills_hour, kills_day, kills_week (kills by players only),
    /// ganks_week, ganks_day, ganks_hour, hauler_ganks_week, last_gank: {time, ship, value}, zkill_ok}.
    /// Cached 10 minutes.
    static func killSummary(system: Int) async -> JSONDict {
        // A failed answer isn't remembered – the next look tries zKillboard again.
        (try? await cached("kills2:\(system)", ttl: 600) { () async throws -> JSONDict in
            let summary = await loadKillSummary(system)
            guard summary.bool("zkill_ok") else { throw RouteError(status: 503, detail: "zKillboard didn't answer") }
            return summary
        }) ?? ["zkill_ok": false]
    }

    /// zKillboard's answer never holds more than 200 kills (its fixed limit, and it doesn't page).
    static let zkillCap = 200

    /// One zKillboard list: the system's killmails over the last `seconds` – up to 200, newest first.
    /// nil if zKillboard didn't answer.
    private static func zkillList(_ system: Int, seconds: Int) async -> [JSONDict]? {
        guard let url = URL(string: "https://zkillboard.com/api/systemID/\(system)/pastSeconds/\(seconds)/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(EngineSettings.userAgent) EveCompanion route checker", forHTTPHeaderField: "User-Agent")
        // zKillboard limits how fast it's asked: on a refusal or time-out wait and try again (3 tries).
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(Double(attempt) * 3)) }
            if let reply = try? await BackendClient.session.data(for: request),
               (reply.1 as? HTTPURLResponse)?.statusCode == 200,
               let list = try? JSON.parse(reply.0) {
                try? await Task.sleep(for: .milliseconds(600))
                return asDicts(list)
            }
        }
        return nil
    }

    /// Where in the system a kill happened, from zKillboard's nearest-object id:
    /// "gate" (stargate), "station" (NPC station or player structure – the undock) or "space" (belts, planets, sites).
    static func place(_ locationID: Int?) -> String {
        guard let id = locationID else { return "space" }
        if (50_000_000..<60_000_000).contains(id) { return "gate" }
        if (60_000_000..<64_000_000).contains(id) || id >= 1_000_000_000_000 { return "station" }
        return "space"
    }

    /// Kills by players only: zKillboard marks kills done purely by NPCs (rats, CONCORD
    /// killing a ganker) as "npc" – those are left out.
    private static func isPlayerKill(_ entry: JSONDict) -> Bool {
        entry.dict("zkb")?.bool("npc") != true
    }

    private static func loadKillSummary(_ system: Int) async -> JSONDict {
        // One list per time frame, so each count is exact.
        guard let week = await zkillList(system, seconds: 604800) else { return ["zkill_ok": false] }
        let day = await zkillList(system, seconds: 86400) ?? []
        let hour = await zkillList(system, seconds: 3600) ?? []
        let dayIDs = Set(day.compactMap { $0.int("killmail_id") })
        let hourIDs = Set(hour.compactMap { $0.int("killmail_id") })

        // Read every killmail of the week from ESI to see the ship and whether CONCORD was on it.
        // Each one is read once and kept, so after the first look only new kills are read.
        let toRead = week
        let ids = toRead.compactMap { $0.int("killmail_id") }
        var known = await HistoryStore.shared.knownKillmails(ids)
        // Rows saved before attackers were kept are read again once.
        let missing = toRead.filter { (known[$0.int("killmail_id") ?? 0]?.string("attackers")) == nil }
        let fetched = (try? await concurrentMap(missing, limit: 10) { entry -> JSONDict? in
            guard let id = entry.int("killmail_id"), let hash = entry.dict("zkb")?.string("hash"),
                  let mail = try? await ESI.get("killmails/\(id)/\(hash)/", auth: false) as? JSONDict else { return nil }
            let attackers = mail.dicts("attackers")
            let concord = attackers.contains { $0.int("corporation_id") == concordCorporation }
            let labels = (entry.dict("zkb")?["labels"] as? [String]) ?? []
            let attackerIDs = attackers.compactMap { $0.int("character_id") }.map(String.init).joined(separator: ",")
            let victimCharacter: Any = mail.dict("victim")?.int("character_id") ?? NSNull()
            let row: JSONDict = [
                "attackers": attackerIDs,
                "victim_character": victimCharacter,
                "killmail_id": id,
                "system_id": mail.int("solar_system_id") ?? system,
                "time": ISODate.parse(mail.string("killmail_time"))?.timeIntervalSince1970 ?? 0,
                "ship_type_id": mail.dict("victim")?.int("ship_type_id") as Any,
                "value": entry.dict("zkb")?.double("totalValue") ?? 0,
                "concord": (concord || labels.contains("ganked")) ? 1 : 0,
                "npc": entry.dict("zkb")?.bool("npc") == true ? 1 : 0,
            ]
            await HistoryStore.shared.saveKillmail(row)
            return row
        }) ?? []
        for row in fetched.compactMap({ $0 }) { if let id = row.int("killmail_id") { known[id] = row } }

        // Ganks. In a gank CONCORD kills the gankers' ships – that loss has CONCORD on it, the
        // victim's usually doesn't. So: a kill by players where one of the attackers was killed by
        // CONCORD in the same system within 15 minutes = a gank (the victim is the one ganked).
        // Also counted: CONCORD on a player kill itself, or zKillboard's own "ganked" label.
        var punished: [Int: [Double]] = [:]   // character → when CONCORD killed them
        for row in known.values where (row.int("concord") ?? 0) == 1 && (row.int("npc") ?? 0) == 1 {
            if let character = row.int("victim_character") {
                punished[character, default: []].append(row.double("time") ?? 0)
            }
        }
        var gankIDs: Set<Int> = []
        for row in known.values where (row.int("npc") ?? 0) == 0 {
            guard let id = row.int("killmail_id") else { continue }
            let time = row.double("time") ?? 0
            let attackers = (row.string("attackers") ?? "").split(separator: ",").compactMap { Int($0) }
            let concorded = attackers.contains { character in
                (punished[character] ?? []).contains { abs($0 - time) <= 900 }
            }
            if concorded || (row.int("concord") ?? 0) == 1 { gankIDs.insert(id) }
        }
        for entry in week where ((entry.dict("zkb")?["labels"] as? [String]) ?? []).contains("ganked") && isPlayerKill(entry) {
            if let id = entry.int("killmail_id") { gankIDs.insert(id) }
        }
        let weekIDs = Set(week.compactMap { $0.int("killmail_id") })
        gankIDs.formIntersection(weekIDs)
        let concordKills = known.values.filter { ($0.int("concord") ?? 0) == 1 && ($0.int("npc") ?? 0) == 1
            && weekIDs.contains($0.int("killmail_id") ?? 0) }.count

        let shipTypes = Array(Set(known.values.compactMap { $0.int("ship_type_id") }))
        var shipInfo: [Int: JSONDict] = [:]
        if !shipTypes.isEmpty, let db = try? SDE.connect() {
            for r in (try? db.query("""
                SELECT t.type_id, t.name, g.name AS group_name FROM types t LEFT JOIN groups g ON g.group_id = t.group_id
                WHERE t.type_id IN (\(shipTypes.map(String.init).joined(separator: ",")))
                """)) ?? [] {
                if let id = r.int("type_id") { shipInfo[id] = r }
            }
        }
        let haulerGanks = gankIDs.filter { id in
            haulerGroups.contains(shipInfo[known[id]?.int("ship_type_id") ?? 0]?.string("group_name") ?? "")
        }
        let last = gankIDs.compactMap { known[$0] }.max { ($0.double("time") ?? 0) < ($1.double("time") ?? 0) }
        let lastGank: JSONDict? = last.map { g in
            [
                "time": g.double("time") ?? 0,
                "ship": shipInfo[g.int("ship_type_id") ?? 0]?.string("name") ?? "Ship",
                "value": g.double("value") ?? 0,
            ]
        }
        // Kills by players per time frame and per place (gate / station / space).
        var placeOf: [Int: String] = [:]
        var locationOf: [Int: Int] = [:]
        for entry in week + day + hour {
            guard let id = entry.int("killmail_id") else { continue }
            let location = entry.dict("zkb")?.int("locationID")
            placeOf[id] = place(location)
            if let location { locationOf[id] = location }
        }
        /// Station kills by exact station / structure: {"60011866": 3}.
        func addAt(_ result: inout JSONDict, _ key: String, _ id: Int) {
            guard placeOf[id] == "station", let location = locationOf[id] else { return }
            var at = (result[key] as? JSONDict) ?? [:]
            at[String(location)] = (at.int(String(location)) ?? 0) + 1
            result[key] = at
        }
        func counts(_ list: [JSONDict]) -> JSONDict {
            var result: JSONDict = ["all": 0, "gate": 0, "station": 0, "space": 0]
            for entry in list where isPlayerKill(entry) {
                let where_ = placeOf[entry.int("killmail_id") ?? 0] ?? "space"
                result["all"] = (result.int("all") ?? 0) + 1
                result[where_] = (result.int(where_) ?? 0) + 1
                addAt(&result, "at", entry.int("killmail_id") ?? 0)
            }
            result["capped"] = list.count >= zkillCap
            return result
        }
        func gankCounts(_ ids: Set<Int>) -> JSONDict {
            var result: JSONDict = ["all": 0, "gate": 0, "station": 0, "space": 0,
                                    "hauler_gate": 0, "hauler_station": 0, "hauler_all": 0]
            for id in ids {
                let where_ = placeOf[id] ?? "space"
                result["all"] = (result.int("all") ?? 0) + 1
                result[where_] = (result.int(where_) ?? 0) + 1
                addAt(&result, "at", id)
                if haulerGanks.contains(id) {
                    addAt(&result, "hauler_at", id)
                    result["hauler_all"] = (result.int("hauler_all") ?? 0) + 1
                    if where_ != "space" { result["hauler_" + where_] = (result.int("hauler_" + where_) ?? 0) + 1 }
                }
            }
            return result
        }
        let concordDay = known.values.filter { ($0.int("concord") ?? 0) == 1 && ($0.int("npc") ?? 0) == 1
            && dayIDs.contains($0.int("killmail_id") ?? 0) }.count
        return [
            "zkill_ok": true,
            "hour": counts(hour),
            "day": counts(day),
            "week": counts(week),
            "ganks_hour": gankCounts(gankIDs.intersection(hourIDs)),
            "ganks_day": gankCounts(gankIDs.intersection(dayIDs)),
            "ganks_week": gankCounts(gankIDs),
            "concord_kills_week": concordKills,
            "concord_kills_day": concordDay,
            "last_gank": lastGank as Any,
        ]
    }

    // MARK: Route

    /// mode: "shortest" · "safest" (high-sec where it can) · "lowest_risk" (safest, then detours
    /// around red systems while it costs no more than `maxExtra` jumps).
    /// `from` / `to` / `via` can be systems, NPC stations or player structures you can dock at.
    /// The route goes start → each stop in `via` (in order) → end.
    static func plan(from fromLocation: Int, to toLocation: Int, via: [Int] = [], mode: String, avoid avoidIn: [Int],
                     maxExtra: Int, penalty: Int = 50, avoidPodKills: Bool = false,
                     preference: String = "secure", quick: Bool = false) async throws -> JSONDict {
        // Every stop on the trip and its system.
        let stops = [fromLocation] + via + [toLocation]
        var stopSystems: [Int] = []
        for (index, stop) in stops.enumerated() {
            guard let system = await Hauling.systemOf(stop) else {
                let which = index == 0 ? "the start" : (index == stops.count - 1 ? "the destination" : "a stop on the way")
                throw RouteError(status: 404, detail: "Couldn't find which system \(which) is in (player structures need docking access).")
            }
            stopSystems.append(system)
        }
        let startDock: Int? = ESI.isSystem(fromLocation) ? nil : fromLocation
        let endDock: Int? = ESI.isSystem(toLocation) ? nil : toLocation
        let fromPlace = await describe(fromLocation)
        let toPlace = await describe(toLocation)
        var viaPlaces: [JSONDict] = []
        for stop in via { viaPlaces.append(await describe(stop)) }
        let keep = Set(stopSystems)   // never avoid a system you asked to go to
        // Like the game's "Avoid systems where pod killing has recently occurred": pods lost there in the last hour.
        // Only the ones the route would actually touch are added (EVE's route finder takes a limited avoid list).
        var podAll: Set<Int> = []
        if avoidPodKills {
            let live = (try? await liveActivity()) ?? [:]
            podAll = Set(live.filter { ($0.value.int("pod_kills") ?? 0) > 0 }.map(\.key)).subtracting(keep)
        }
        var podSystems: [Int] = []
        var avoid = avoidIn

        /// Leg by leg; the stops' positions in the joined path are returned too.
        func build(_ flag: String, _ avoiding: [Int]) async throws -> (path: [Int], stopIndex: [Int]) {
            var path: [Int] = [stopSystems[0]]
            var stopIndex: [Int] = [0]
            for leg in 1..<stopSystems.count {
                let part = try await esiRoute(stopSystems[leg - 1], stopSystems[leg], flag: flag,
                                              avoid: avoiding.filter { !keep.contains($0) }, penalty: penalty)
                path.append(contentsOf: part.dropFirst())
                stopIndex.append(path.count - 1)
            }
            return (path, stopIndex)
        }

        // Route like the game: its preference (Shorter / Safer / Less Secure) and security penalty.
        // (Old saved modes "shortest" / "safest" still work.)
        let flag: String = mode == "shortest" ? "shortest" : (mode == "safest" ? "secure" : preference)
        var built = try await build(flag, avoid)
        for _ in 0..<4 where !podAll.isEmpty {
            let onRoute = Set(built.path).intersection(podAll).subtracting(avoid)
            guard !onRoute.isEmpty, let rerouted = try? await build(flag, avoid + Array(onRoute)) else { break }
            avoid += Array(onRoute)
            podSystems += Array(onRoute)
            built = rerouted
        }
        // quick = the route and CCP's figures straight away; kills and ganks (zKillboard) come in a second call.
        var rows = await evaluate(built.path, startDock: startDock, endDock: endDock, quick: quick)
        var detoured: [String] = []
        let baseJumps = max(built.path.count - 1, 0)

        if mode == "lowest_risk" && !quick {
            var avoiding = Set(avoid)
            for _ in 0..<3 {
                let reds = rows.filter { $0.string("light") == "red" }
                    .compactMap { $0.int("system_id") }
                    .filter { !keep.contains($0) && !avoiding.contains($0) }
                guard !reds.isEmpty else { break }
                let tryAvoid = avoiding.union(reds)
                guard let alternative = try? await build(flag, Array(tryAvoid)),
                      alternative.path.count > 1, alternative.path.count - 1 <= baseJumps + maxExtra else { break }
                // Only take the detour if it's actually safer: fewer red systems than now.
                let newRows = await evaluate(alternative.path, startDock: startDock, endDock: endDock)
                func redCount(_ list: [JSONDict]) -> Int { list.filter { $0.string("light") == "red" }.count }
                guard redCount(newRows) < redCount(rows) else { break }
                for name in rows.filter({ reds.contains($0.int("system_id") ?? 0) }).compactMap({ $0.string("name") })
                where !detoured.contains(name) { detoured.append(name) }
                avoiding = tryAvoid
                built = alternative
                rows = newRows
            }
        }

        let order = ["green": 0, "amber": 1, "red": 2]
        let worst = rows.compactMap { $0.string("light") }.max { (order[$0] ?? 0) < (order[$1] ?? 0) } ?? "green"
        let first = await HistoryStore.shared.systemActivity([stopSystems[0]], since: 0).firstHour
        func sum(_ key: String) -> Int { rows.reduce(0) { $0 + ($1.int(key) ?? 0) } }
        // Where each stop sits on the path, and the station / structure to send as its waypoint.
        let anchors: [JSONDict] = zip(built.stopIndex, stops).map { ["index": $0.0, "location_id": $0.1] }
        let lowest: Any = rows.compactMap { $0.double("security") }.min().map { $0 as Any } ?? NSNull()
        let watching: Any = first.map { $0 as Any } ?? NSNull()
        return [
            "mode": mode,
            "preference": flag,
            "from_place": fromPlace,
            "to_place": toPlace,
            "via_places": viaPlaces,
            "anchors": anchors,
            "pod_kill_systems_avoided": podSystems.count,
            "jumps": max(built.path.count - 1, 0),
            "base_jumps": baseJumps,
            "detoured": detoured,
            "worst": worst,
            "lowest_security": lowest,
            "kills_last_hour": sum("kills_hour"),
            "ganks_week": sum("ganks_week"),
            "hauler_ganks_week": sum("hauler_ganks_week"),
            "watching_since": watching,
            "systems": rows,
        ]
    }

    /// CCP's route finder (ESI, 2025 version: POST /route/{origin}/{destination} with a JSON body).
    /// flag: "shortest" → Shorter, anything else → Safer. Cached an hour.
    static func esiRoute(_ origin: Int, _ destination: Int, flag: String, avoid: [Int], penalty: Int = 50) async throws -> [Int] {
        if origin == destination { return [origin] }
        let preference = flag == "shortest" ? "Shorter" : (flag == "insecure" ? "LessSecure" : "Safer")
        let avoidList = avoid.filter { $0 != origin && $0 != destination }.sorted()
        let strictness = min(max(penalty, 0), 100)
        let key = "esiroute3:\(origin):\(destination):\(preference):\(strictness):\(avoidList.map(String.init).joined(separator: ","))"
        return try await cached(key, ttl: 3600) { () async throws -> [Int] in
            guard let url = URL(string: "https://esi.evetech.net/route/\(origin)/\(destination)") else { return [] }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2025-09-30", forHTTPHeaderField: "X-Compatibility-Date")
            request.setValue(EngineSettings.userAgent, forHTTPHeaderField: "User-Agent")
            var body: JSONDict = ["preference": preference, "security_penalty": strictness]
            if !avoidList.isEmpty { body["avoid_systems"] = avoidList }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await BackendClient.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                if status == 404 { throw RouteError(status: 404, detail: "EVE found no route between those systems (with the systems you avoid).") }
                throw ESIError(status: status, path: url.absoluteString, body: String(decoding: data, as: UTF8.self))
            }
            let ids = systemIDs(in: try JSON.parse(data))
            if ids.isEmpty { throw RouteError(status: 502, detail: "EVE's route service sent back no systems.") }
            return ids
        }
    }

    /// The route as system ids – a plain list, or wrapped ({"route": [...]}, items as ids or {system_id}).
    private static func systemIDs(in value: Any) -> [Int] {
        if let list = value as? [Any] {
            return list.compactMap { item in
                if let n = item as? NSNumber { return n.intValue }
                if let d = item as? JSONDict { return d.int("system_id") ?? d.int("solar_system_id") ?? d.int("id") }
                return nil
            }
        }
        if let dict = value as? JSONDict {
            for key in ["route", "systems", "path"] {
                if let inner = dict[key] { return systemIDs(in: inner) }
            }
        }
        return []
    }

    /// Every system on the path with its numbers and traffic light.
    static func evaluate(_ path: [Int], startDock: Int? = nil, endDock: Int? = nil, quick: Bool = false) async -> [JSONDict] {
        guard !path.isEmpty, let db = try? SDE.connect() else { return [] }
        var info: [Int: JSONDict] = [:]
        for r in (try? db.query("SELECT system_id, name, security, region_name FROM solar_systems WHERE system_id IN (\(path.map(String.init).joined(separator: ",")))")) ?? [] {
            if let id = r.int("system_id") { info[id] = r }
        }
        let live = (try? await liveActivity()) ?? [:]
        let now = Date().timeIntervalSince1970
        let day = await HistoryStore.shared.systemActivity(path, since: now - 86400)
        let week = await HistoryStore.shared.systemActivity(path, since: now - 7 * 86400)
        // One system at a time – zKillboard turns away apps that ask too quickly.
        let kills: [JSONDict] = quick ? [] : ((try? await concurrentMap(path, limit: 1) { await killSummary(system: $0) }) ?? [])

        return path.enumerated().map { index, id in
            // The station / structure you start or end at, if one was picked (both, for a one-system trip).
            var dock: Int?
            if index == path.count - 1 { dock = endDock }
            if index == 0 { dock = startDock ?? (path.count == 1 ? endDock : nil) }
            return rate(index: index, id: id, path: path, info: info[id], live: live[id] ?? [:],
                        dayRow: day.rows[id], weekRow: week.rows[id], k: index < kills.count ? kills[index] : [:],
                        dock: dock, pending: quick)
        }
    }

    /// One system's numbers and traffic light.
    ///
    /// Which kills count: passing through, only kills on the gates (that's where you are); at the
    /// start and the end also kills at the station / undock. Kills out in belts and sites never count.
    ///
    /// Red:   low/null-sec · a hauler ganked here in the last 24 h · 2+ haulers ganked this week ·
    ///        a sudden spike (3+ kills that count in the last hour, 4× the system's normal hourly rate)
    /// Amber: any other gank that counts in the last 24 h · a hauler ganked this week ·
    ///        kills that count in 24 h at 3+ and either 2× the system's normal day or
    ///        more than 5 per 1,000 ships passing through
    /// Green: everything else
    private static func rate(index: Int, id: Int, path: [Int], info: JSONDict?, live: JSONDict,
                             dayRow: JSONDict?, weekRow: JSONDict?, k: JSONDict, dock: Int? = nil,
                             pending: Bool = false) -> JSONDict {
        let sec = info?.double("security") ?? 0
        let endpoint = index == 0 || index == path.count - 1
        let zkillOK = k.bool("zkill_ok")
        let hour = k.dict("hour") ?? [:]
        let day = k.dict("day") ?? [:]
        let week = k.dict("week") ?? [:]
        let ganksDay = k.dict("ganks_day") ?? [:]
        let ganksWeek = k.dict("ganks_week") ?? [:]

        // CCP's figures (every player ship lost, whoever killed it).
        let ccpHour = live.int("ship_kills") ?? 0
        let ccpDay = dayRow?.int("ship_kills") ?? 0
        let ccpWeek = weekRow?.int("ship_kills") ?? 0
        let ccpDayHours = dayRow?.int("hours") ?? 0
        let ccpWeekHours = weekRow?.int("hours") ?? 0
        let jumpsHour = live.int("jumps")
        // Ships passing through in a day: the app's own records once it has most of a day, else this hour × 24.
        let jumpsDay: Double = (dayRow?.int("hours") ?? 0) >= 20 ? Double(dayRow?.int("jumps") ?? 0) : Double(jumpsHour ?? 0) * 24

        // Shown counts: kills by players (zKillboard). When zKillboard's 200 limit is hit and the app has
        // recorded the period, CCP's count less the criminals CONCORD killed is closer to the truth.
        func shown(_ counts: JSONDict, ccp: Int, ccpHours: Int, needHours: Int, concord: Int) -> (value: Int?, capped: Bool, fromCCP: Bool) {
            if !zkillOK { return ccpHours >= needHours ? (ccp, false, true) : (nil, false, true) }
            let n = counts.int("all") ?? 0
            if counts.bool("capped") {
                if ccpHours >= needHours { return (max(ccp - concord, n), false, true) }
                return (n, true, false)
            }
            return (n, false, false)
        }
        let concordDay = k.int("concord_kills_day") ?? 0
        let concordWeek = k.int("concord_kills_week") ?? 0
        let showHour = zkillOK ? (value: Optional(hour.int("all") ?? 0), capped: hour.bool("capped"), fromCCP: false)
                               : (value: Optional(ccpHour), capped: false, fromCCP: true)
        let showDay = shown(day, ccp: ccpDay, ccpHours: ccpDayHours, needHours: 20, concord: concordDay)
        let showWeek = shown(week, ccp: ccpWeek, ccpHours: ccpWeekHours, needHours: 160, concord: concordWeek)

        // Kills that count for this system's role on the route.
        // Undock kills at an end: only that station's when one was picked, else any station in the system.
        func atDock(_ c: JSONDict, _ key: String, all: String) -> Int {
            guard endpoint else { return 0 }
            if let dock { return (c[key] as? JSONDict)?.int(String(dock)) ?? 0 }
            return c.int(all) ?? 0
        }
        func counting(_ c: JSONDict) -> Int { (c.int("gate") ?? 0) + atDock(c, "at", all: "station") }
        let countHour = counting(hour)
        let countDay = counting(day)
        let countWeek = counting(week)
        let normalHour = Double(countWeek) / 168
        let normalDay = Double(countWeek) / 7
        let gankDay = counting(ganksDay)
        let haulerDay = (ganksDay.int("hauler_gate") ?? 0) + atDock(ganksDay, "hauler_at", all: "hauler_station")
        let haulerWeek = (ganksWeek.int("hauler_gate") ?? 0) + atDock(ganksWeek, "hauler_at", all: "hauler_station")
        let perThousand: Double? = jumpsDay > 0 ? Double(countDay) / jumpsDay * 1000 : nil
        let whereText = endpoint ? (dock != nil ? "on gates or at your undock" : "on gates or at the undock") : "on gates"

        var light = "green"
        var reasons: [String] = []
        func red(_ text: String) { light = "red"; reasons.append(text) }
        func amber(_ text: String) { if light != "red" { light = "amber" }; reasons.append(text) }

        if sec < 0.45 { red(sec <= 0 ? "Null-sec" : "Low-sec – no CONCORD") }
        if zkillOK {
            if haulerDay > 0 { red("\(haulerDay) hauler\(haulerDay == 1 ? "" : "s") ganked \(whereText) in the last 24 h") }
            if haulerWeek >= 2 { red("\(haulerWeek) haulers ganked \(whereText) this week") }
            if countHour >= 3 && Double(countHour) >= normalHour * 4 {
                red("\(countHour) ships killed \(whereText) in the last hour – \(normalHour < 0.5 ? "it's usually quiet" : "about \(Int((Double(countHour) / max(normalHour, 0.01)).rounded()))× normal")")
            }
            if gankDay > haulerDay { amber("\(gankDay - haulerDay) other gank\(gankDay - haulerDay == 1 ? "" : "s") \(whereText) in the last 24 h") }
            if haulerWeek == 1 && haulerDay == 0 { amber("1 hauler ganked \(whereText) this week") }
            if countDay >= 3 && Double(countDay) >= normalDay * 2 && countWeek > countDay {
                amber("\(countDay) ships killed \(whereText) in 24 h – double its usual")
            } else if countDay >= 3, let perThousand, perThousand > 5 {
                amber("\(countDay) ships killed \(whereText) in 24 h – \(String(format: "%.1f", perThousand)) per 1,000 ships passing")
            }
        }
        if reasons.isEmpty && !pending {
            let spaceDay = (day.int("all") ?? 0) - counting(day)
            reasons.append(spaceDay > 0 ? "Quiet on the way through (\(spaceDay) kill\(spaceDay == 1 ? "" : "s") elsewhere in the system)" : "Quiet")
        }
        if pending {
            reasons.append("Checking kills and ganks…")
            if light == "green" { light = "pending" }   // grey until the kill data is in
        }
        else if !zkillOK { reasons.append("zKillboard didn't answer – ganks unknown") }

        // Breakdown for the tooltips.
        func split(_ c: JSONDict) -> String {
            "gates \(c.int("gate") ?? 0) · station/undock \(c.int("station") ?? 0) · belts & sites \(c.int("space") ?? 0)"
        }
        // Hoisted so the dictionary below stays quick to type-check.
        let regionOut: Any = info?.string("region_name") ?? NSNull()
        let jumpsOut: Any = jumpsHour.map { $0 as Any } ?? NSNull()
        let dayOut: Any = showDay.value.map { $0 as Any } ?? NSNull()
        let weekOut: Any = showWeek.value.map { $0 as Any } ?? NSNull()
        let perThousandOut: Any = perThousand.map { $0 as Any } ?? NSNull()
        let concordOut: Any = k.int("concord_kills_week").map { $0 as Any } ?? NSNull()
        let lastGankOut: Any = k["last_gank"] ?? NSNull()
        let gankSplit = "gates \(ganksWeek.int("gate") ?? 0) · station/undock \(ganksWeek.int("station") ?? 0) · belts & sites \(ganksWeek.int("space") ?? 0)"
        let hourValue: Int = showHour.value ?? 0
        return [
            "system_id": id,
            "name": info?.string("name") ?? String(id),
            "region": regionOut,
            "security": sec,
            "role": endpoint ? (dock != nil ? "dock" : "endpoint") : "transit",
            "jumps_hour": jumpsOut,
            "kills_hour": hourValue,
            "kills_hour_capped": showHour.capped,
            "pods_hour": live.int("pod_kills") ?? 0,
            "kills_day": dayOut,
            "kills_day_capped": showDay.capped,
            "kills_day_ccp": showDay.fromCCP,
            "kills_week": weekOut,
            "kills_week_capped": showWeek.capped,
            "kills_week_ccp": showWeek.fromCCP,
            "split_hour": split(hour),
            "split_day": split(day),
            "split_week": split(week),
            "per_thousand": perThousandOut,
            "normal_day": normalDay,
            "concord_kills_week": concordOut,
            "kills_from": zkillOK ? "players" : "ccp",
            "ccp_hour": ccpHour,
            "ccp_day": ccpDay,
            "ccp_day_hours": ccpDayHours,
            "ccp_week": ccpWeek,
            "ccp_week_hours": ccpWeekHours,
            "ganks_week": ganksWeek.int("all") ?? 0,
            "ganks_day": ganksDay.int("all") ?? 0,
            "hauler_ganks_week": ganksWeek.int("hauler_all") ?? 0,
            "hauler_ganks_day_counting": haulerDay,   // haulers ganked where you'd be, last 24 h (Watch List alerts)
            "gank_split_week": gankSplit,
            "last_gank": lastGankOut,
            "zkill_ok": zkillOK,
            "pending": pending,
            "light": light,
            "reasons": reasons,
        ]
    }

    // MARK: Optimise stop order (the game's "Optimize route")

    /// Put the stops in the order with the fewest jumps from start to end (start and end stay put).
    /// Up to 7 stops: every order is tried; more: nearest stop next. Returns the stops' location ids in order.
    static func optimiseStops(from: Int, to: Int, via: [Int], preference: String, penalty: Int, avoid: [Int]) async throws -> JSONDict {
        guard via.count >= 2 else { return ["via": via, "jumps_before": NSNull(), "jumps_after": NSNull()] }
        let places = [from] + via + [to]
        var systems: [Int] = []
        for place in places {
            guard let system = await Hauling.systemOf(place) else {
                throw RouteError(status: 404, detail: "Couldn't find which system a stop is in.")
            }
            systems.append(system)
        }
        // Jumps between every pair (EVE's route finder, same settings as the plan).
        var jumps: [[Int]] = Array(repeating: Array(repeating: 0, count: places.count), count: places.count)
        for a in 0..<places.count {
            for b in 0..<places.count where a != b {
                let route = try await esiRoute(systems[a], systems[b], flag: preference,
                                               avoid: avoid.filter { !systems.contains($0) }, penalty: penalty)
                jumps[a][b] = max(route.count - 1, 0)
            }
        }
        let last = places.count - 1
        func length(_ order: [Int]) -> Int {
            var total = 0
            var at = 0
            for stop in order { total += jumps[at][stop]; at = stop }
            return total + jumps[at][last]
        }
        let original = Array(1...via.count)
        var best = original
        if via.count <= 7 {
            func permute(_ chosen: [Int], _ left: [Int]) {
                if left.isEmpty {
                    if length(chosen) < length(best) { best = chosen }
                    return
                }
                for (i, stop) in left.enumerated() {
                    var rest = left
                    rest.remove(at: i)
                    permute(chosen + [stop], rest)
                }
            }
            permute([], original)
        } else {
            var left = Set(original)
            var at = 0
            var order: [Int] = []
            while !left.isEmpty {
                let next = left.min { jumps[at][$0] < jumps[at][$1] }!
                order.append(next)
                left.remove(next)
                at = next
            }
            if length(order) < length(best) { best = order }
        }
        return ["via": best.map { places[$0] }, "jumps_before": length(original), "jumps_after": length(best)]
    }

    // MARK: Places (systems, NPC stations, player structures you can dock at)

    static let searchScope = "esi-search.search_structures.v1"

    /// Systems from the static data, plus – with the search permission – NPC stations and the player
    /// structures this character may dock at (refineries, citadels, engineering complexes…).
    /// {places: [{location_id, kind, name, system_id, system_name, security, label}], can_search_structures}
    static func searchPlaces(_ text: String) async -> JSONDict {
        let query = text.trimmingCharacters(in: .whitespaces)
        let hubStations = Set(Market.hubStations.map(\.1))
        var places: [JSONDict] = []
        var seen: Set<Int> = []
        func add(_ d: JSONDict) {
            guard let id = d.int("location_id"), (d.int("system_id") ?? 0) != 0, !seen.contains(id) else { return }
            seen.insert(id)
            var place = d
            place["hub"] = hubStations.contains(id)
            if hubStations.contains(id) { place["label"] = "Trade hub" }
            places.append(place)
        }
        let db = try? SDE.connect()
        var systemInfo: [Int: JSONDict] = [:]
        func stationPlace(_ r: JSONDict) -> JSONDict {
            let system = r.int("system_id") ?? 0
            if systemInfo[system] == nil, let row = (try? db?.query("SELECT system_id, name, security FROM solar_systems WHERE system_id = ?", [system]))?.first {
                systemInfo[system] = row
            }
            return ["location_id": r.int("station_id") ?? 0, "kind": "station", "name": r.string("name") ?? "",
                    "system_id": system, "system_name": systemInfo[system]?.string("name") ?? "",
                    "security": systemInfo[system]?.double("security") ?? 0, "label": "Station"]
        }

        // 1. Systems, each followed by every station in it (trade hub first) – "jita" lists Jita and its stations.
        let systems = (try? SDE.searchSystems(query, limit: 6)) ?? []
        await loadStationNames()
        let listStationsOf = systems.prefix(3).compactMap { $0.int("system_id") }
        let stationsBySystem = Dictionary(grouping: await HistoryStore.shared.stationsIn(listStationsOf), by: { $0.int("system_id") ?? 0 })
        for r in systems {
            let id = r.int("system_id") ?? 0
            systemInfo[id] = r
            add(["location_id": id, "kind": "system", "name": r.string("name") ?? "",
                 "system_id": id, "system_name": r.string("name") ?? "",
                 "security": r.double("security") ?? 0, "label": "System"])
            let stations = (stationsBySystem[id] ?? []).sorted {
                let hubA = hubStations.contains($0.int("station_id") ?? 0), hubB = hubStations.contains($1.int("station_id") ?? 0)
                return hubA != hubB ? hubA : ($0.string("name") ?? "") < ($1.string("name") ?? "")
            }
            if stations.isEmpty, listStationsOf.contains(id) {
                // Station names not loaded yet – ask EVE for this system's stations.
                let info: Any? = try? await cached("systeminfo:\(id)", ttl: 7 * 24 * 3600) { () async throws -> Any in
                    try await ESI.get("universe/systems/\(id)/", auth: false)
                }
                let ids = ((info as? JSONDict)?["stations"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
                for d in (try? await concurrentMap(ids, limit: 6) { await describe($0) }) ?? [] { add(d) }
            }
            for station in stations { add(stationPlace(station)) }
        }
        guard query.count >= 3 else { return ["places": places, "can_search_structures": true] }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        func matches(_ name: String) -> Bool { words.allSatisfy { name.localizedCaseInsensitiveContains($0) } }

        // 2. Places you have things in (your hangars, the refinery you use).
        let mine = (try? await Market.stockLocations()) ?? []
        let mineMatching = mine.filter { matches($0.string("name") ?? "") }
            .compactMap { $0.int("location_id") }.filter { !ESI.isSystem($0) }
        for d in (try? await concurrentMap(Array(mineMatching.prefix(10)), limit: 4) { await describe($0) }) ?? [] { add(d) }

        // 3. Any NPC station with every typed word somewhere in its name ("duvolle", "navy assembly dodixie").
        for r in await HistoryStore.shared.searchStationNames(words, limit: 20) { add(stationPlace(r)) }

        // 4. EVE's own search: stations and every structure you're allowed to dock at.
        let canSearch = await EveAuth.shared.grantedScopes().contains(searchScope)
        if canSearch {
            let found: JSONDict = (try? await cached("placesearch:\(query.lowercased())", ttl: 600) { () async throws -> JSONDict in
                let cid = try await EveAuth.shared.characterID()
                return (try await ESI.get("characters/\(cid)/search/", params: [
                    "categories": "station,structure", "search": query, "strict": "false",
                ]) as? JSONDict) ?? [:]
            }) ?? [:]
            let stationIDs = Array(((found["station"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }.prefix(15))
            let structureIDs = Array(((found["structure"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }.prefix(15))
            let details = (try? await concurrentMap(stationIDs + structureIDs, limit: 6) { await describe($0) }) ?? []
            for d in details { add(d) }
        }
        return ["places": places, "can_search_structures": canSearch]
    }

    /// Fill the app's own list of NPC station names (a few calls to EVE, once – then kept).
    static func loadStationNames() async {
        _ = try? await cached("station_names_loaded", ttl: 24 * 3600) { () async throws -> Bool in
            guard let rows = try? SDE.connect().query("SELECT station_id, system_id FROM npc_stations"), !rows.isEmpty else {
                throw RouteError(status: 503, detail: "Station list not ready yet")   // static data still rebuilding – try later
            }
            let have = await HistoryStore.shared.stationNameIDs()
            var systemOf: [Int: Int] = [:]
            for r in rows { if let id = r.int("station_id") { systemOf[id] = r.int("system_id") ?? 0 } }
            let missing = systemOf.keys.filter { !have.contains($0) }
            guard !missing.isEmpty else { return true }
            let names = await ESI.universeNames(Array(missing))
            await HistoryStore.shared.saveStationNames(names.map { (id: $0.key, name: $0.value, system: systemOf[$0.key] ?? 0) })
            return true
        }
    }

    /// Name, kind and system of any location: {location_id, kind, name, system_id, system_name, security, label}.
    static func describe(_ location: Int) async -> JSONDict {
        let db = try? SDE.connect()
        func system(_ id: Int?) -> JSONDict {
            let rows: [JSONDict] = id.flatMap { try? db?.query("SELECT name, security FROM solar_systems WHERE system_id = ?", [$0]) } ?? []
            guard let id, let r = rows.first else { return ["system_id": id ?? 0, "system_name": "", "security": 0] }
            return ["system_id": id, "system_name": r.string("name") ?? "", "security": r.double("security") ?? 0]
        }
        if ESI.isSystem(location) {
            var d = system(location)
            d["location_id"] = location
            d["kind"] = "system"
            d["name"] = d.string("system_name") ?? String(location)
            d["label"] = "System"
            return d
        }
        if ESI.isStation(location) {
            // Name and system from the app's own station list first; EVE only if it isn't there.
            var info: JSONDict = [:]
            if let row = (await HistoryStore.shared.stationRow(location)) {
                info = ["name": row.string("name") ?? "", "system_id": row.int("system_id") ?? 0]
            } else {
                let station: Any? = try? await cached("station:\(location)", ttl: 7 * 24 * 3600) { () async throws -> Any in
                    try await ESI.get("universe/stations/\(location)/", auth: false)
                }
                info = (station as? JSONDict) ?? [:]
            }
            var d = system(info.int("system_id"))
            d["location_id"] = location
            d["kind"] = "station"
            d["name"] = info.string("name") ?? "Station \(location)"
            d["label"] = "Station"
            return d
        }
        let structure: Any? = try? await cached("structure:\(location)", ttl: 24 * 3600) { () async throws -> Any in
            try await ESI.get("universe/structures/\(location)/")
        }
        var info = (structure as? JSONDict) ?? [:]
        if let system = info.int("solar_system_id") {
            await HistoryStore.shared.saveStructure(location, name: info.string("name"), system: system, type: info.int("type_id"))
        } else if let known = await HistoryStore.shared.structureRow(location) {
            // EVE wouldn't describe it this time – use what the app learned before.
            info = ["name": known.string("name") ?? "", "solar_system_id": known.int("system_id") ?? 0,
                    "type_id": known.int("type_id") ?? NSNull()]
        }
        if info.string("name") == nil || info.string("name") == "" {
            let name = await ESI.placeName(location)   // the same lookup the Pilot page uses
            if !name.hasPrefix("Structure ") { info["name"] = name }
        }
        if info.int("solar_system_id") == nil, let name = info.string("name"), let system = Hauling.systemFromName(name) {
            info["solar_system_id"] = system   // name starts with the system's name
            await HistoryStore.shared.saveStructure(location, name: name, system: system, type: nil)
        }
        var d = system(info.int("solar_system_id"))
        d["location_id"] = location
        d["kind"] = "structure"
        d["name"] = info.string("name") ?? "Structure \(location)"
        var label = "Structure"
        let typeRows: [JSONDict] = info.int("type_id").flatMap { type in
            try? db?.query("SELECT t.name, g.name AS group_name FROM types t LEFT JOIN groups g ON g.group_id = t.group_id WHERE t.type_id = ?", [type])
        } ?? []
        if let r = typeRows.first {
            label = "\(r.string("group_name") ?? "Structure") (\(r.string("name") ?? ""))"
        }
        d["label"] = label
        return d
    }

    /// Where the character is right now: their station / structure if docked, else their system.
    static func currentLocation() async throws -> JSONDict {
        let cid = try await EveAuth.shared.characterID()
        guard let here = try await ESI.get("characters/\(cid)/location/") as? JSONDict else {
            throw RouteError(status: 502, detail: "EVE didn't say where you are.")
        }
        let location = here.int("station_id") ?? here.int("structure_id") ?? here.int("solar_system_id") ?? 0
        guard location != 0 else { throw RouteError(status: 502, detail: "EVE didn't say where you are.") }
        // Docked in a player structure: EVE's answer already says which system – remember it, like the Pilot page.
        if let structureID = here.int("structure_id"), let system = here.int("solar_system_id") {
            let name = await ESI.placeName(structureID)
            await HistoryStore.shared.saveStructure(structureID, name: name.hasPrefix("Structure ") ? nil : name,
                                                    system: system, type: nil)
        }
        return await describe(location)
    }

    // MARK: Send to game

    static let waypointScope = "esi-ui.write_waypoint.v1"

    /// Set the in-game autopilot: just the destination (the game picks the route), or the start plus
    /// every system as a waypoint so the game follows this exact route from wherever you are now.
    /// Send the route to the game with as few waypoints as possible: the start, your stops and the end,
    /// plus only the extra systems needed to keep the game's autopilot on this exact path.
    /// `anchors` = [(position on the path, station/structure/system to send)]; `preference` = the
    /// autopilot setting in your game ("shortest" / "secure" / "insecure").
    /// Returns the waypoints sent.
    @discardableResult
    /// `gameAvoid` = what your in-game autopilot avoids by itself (your avoidance list, pod-kill systems),
    /// so the check matches what the game will really do.
    static func sendRoute(path: [Int], anchors: [(index: Int, location: Int)], preference: String,
                          destinationOnly: Bool, everySystem: Bool = false, penalty: Int = 50,
                          gameAvoid: [Int] = [], gameAvoidsPodKills: Bool = false) async throws -> [Int] {
        var avoidInGame = Set(gameAvoid)
        var podAll: Set<Int> = []
        if gameAvoidsPodKills {
            let live = (try? await liveActivity()) ?? [:]
            podAll = Set(live.filter { ($0.value.int("pod_kills") ?? 0) > 0 }.map(\.key)).subtracting(path)
        }
        avoidInGame.subtract(path)   // the planned route goes there anyway – waypoints will take the game through
        guard await EveAuth.shared.grantedScopes().contains(waypointScope) else {
            throw RouteError(status: 403, detail: "Log out and log in again (Pilot tab) to let the app set waypoints in the game.")
        }
        var targets: [Int] = []
        if destinationOnly {
            if let last = anchors.last { targets = [last.location] }
        } else {
            for (n, anchor) in anchors.enumerated() {
                if n > 0 {
                    let from = anchors[n - 1].index
                    if everySystem {
                        // Always exact, whatever the game's own settings: every system in between.
                        if anchor.index - from > 1 { targets.append(contentsOf: path[(from + 1)..<anchor.index]) }
                    } else {
                        targets.append(contentsOf: try await extraWaypoints(path, from: from, to: anchor.index, preference: preference,
                                                                            penalty: penalty, avoid: Array(avoidInGame), podKills: podAll))
                    }
                }
                targets.append(anchor.location)
            }
        }
        var cleaned: [Int] = []
        for id in targets where cleaned.last != id { cleaned.append(id) }
        for (index, target) in cleaned.enumerated() {
            _ = try await ESI.send("ui/autopilot/waypoint/", params: [
                "add_to_beginning": "false",
                "clear_other_waypoints": index == 0 ? "true" : "false",
                "destination_id": String(target),
            ], method: "POST")
        }
        return cleaned
    }

    /// Systems strictly between path[from] and path[to] that must be waypoints so the game, routing on
    /// its own between waypoints, flies exactly this path. Goes as far as the game's own route still
    /// matches, sets a waypoint there, and carries on.
    private static func extraWaypoints(_ path: [Int], from: Int, to: Int, preference: String,
                                       penalty: Int, avoid: [Int], podKills: Set<Int> = []) async throws -> [Int] {
        /// What the game would fly between two systems on its own, steering round pod-kill systems as it goes.
        func gameRoute(_ a: Int, _ b: Int) async throws -> [Int] {
            var avoiding = avoid
            var route = try await esiRoute(a, b, flag: preference, avoid: avoiding, penalty: penalty)
            for _ in 0..<3 where !podKills.isEmpty {
                let bad = Set(route).intersection(podKills).subtracting(avoiding)
                guard !bad.isEmpty else { break }
                avoiding += Array(bad)
                route = try await esiRoute(a, b, flag: preference, avoid: avoiding, penalty: penalty)
            }
            return route
        }
        var extra: [Int] = []
        var current = from
        while current < to {
            var reach = current + 1
            // Furthest point the game would reach by itself along this path (checked from the far end).
            var candidate = to
            while candidate > current + 1 {
                let route = try await gameRoute(path[current], path[candidate])
                if route == Array(path[current...candidate]) { reach = candidate; break }
                candidate -= 1
            }
            if reach < to { extra.append(path[reach]) }
            current = reach
        }
        return extra
    }
}
