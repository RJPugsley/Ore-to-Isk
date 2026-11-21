import Foundation

/// An ESI call that didn't return 2xx .
struct ESIError: LocalizedError {
    let status: Int
    let path: String
    let body: String

    var errorDescription: String? {
        if status == 420 || status == 429 {
            return "EVE is asking the app to slow down (too many requests). Wait a minute, then try again."
        }
        return "Client error '\(status)' for url '\(path)': \(body)"
    }

    /// The token doesn't carry the scope this call needs.
    var isPermissionDenied: Bool { status == 401 || status == 403 }

    /// EVE asked us to slow down (420 = too many errors, 429 = too many requests).
    var isRateLimited: Bool { status == 420 || status == 429 }
}

/// One gate for every ESI call: when EVE says "slow down", all calls wait together
/// instead of each one failing (and adding to the error count).
actor ESIGate {
    static let shared = ESIGate()
    private var pausedUntil: Date?

    func waitIfPaused() async {
        while let until = pausedUntil, until > Date() {
            try? await Task.sleep(nanoseconds: UInt64(until.timeIntervalSinceNow * 1_000_000_000) + 50_000_000)
        }
        pausedUntil = nil
    }

    /// Returns true if this call started a new pause (so only one message is shown).
    @discardableResult
    func pause(seconds: Double) -> Bool {
        let until = Date().addingTimeInterval(min(max(seconds, 1), 90))
        if let current = pausedUntil, current >= until { return false }
        let fresh = pausedUntil == nil || pausedUntil! < Date()
        pausedUntil = until
        return fresh
    }

    /// Seconds to wait, from EVE's headers (Retry-After, or the error-limit reset).
    static func wait(from http: HTTPURLResponse) -> Double {
        if let value = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(value) { return seconds }
        if let value = http.value(forHTTPHeaderField: "X-ESI-Error-Limit-Reset"), let seconds = Double(value) { return seconds }
        return 30
    }

    /// Ease off before EVE blocks us: few errors left in this window → wait for it to reset.
    func check(_ http: HTTPURLResponse) {
        if let remain = http.value(forHTTPHeaderField: "X-ESI-Error-Limit-Remain").flatMap(Int.init), remain < 15 {
            pause(seconds: Self.wait(from: http))
        }
        if let remain = http.value(forHTTPHeaderField: "X-Ratelimit-Remaining").flatMap(Int.init), remain < 5 {
            pause(seconds: 5)
        }
    }

    static func tellUser(_ seconds: Double) async {
        await MainActor.run {
            ActivityCenter.shared.flash("EVE asked the app to slow down – waiting \(Int(seconds.rounded())) s")
        }
    }
}

/// HTTP status of an error if it came from ESI .
func httpStatus(of error: Error) -> Int? {
    (error as? ESIError)?.status
}

/// Originally `esi.py`.
enum ESI {
    static let base = "https://esi.evetech.net/latest"
    static let datasource = "tranquility"

    // MARK: - Low-level helpers

    static func url(_ endpoint: String, params: [String: String]) -> URL {
        let trimmed = endpoint.hasPrefix("/") ? String(endpoint.dropFirst()) : endpoint
        var components = URLComponents(string: "\(base)/\(trimmed)")!
        var query = [URLQueryItem(name: "datasource", value: datasource)]
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            query.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = query
        return components.url!
    }

    static func send(_ endpoint: String, params: [String: String] = [:], auth: Bool = true,
                     method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        PageMemo.deps?.usedLiveData()   // read straight from EVE (not a timed copy) – page always recalculates
        let target = url(endpoint, params: params)
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(EngineSettings.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth {
            let token = try await EveAuth.shared.accessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // EVE's servers sometimes time out (502/503/504) or the connection drops. Reads are
        // safe to repeat, so a GET is tried up to 3 times (waiting 1 s, then 3 s) before giving up.
        // During daily downtime there's no point waiting – say so straight away.
        let delays: [UInt64] = (method == "GET" && !EveDowntime.isNow()) ? [1, 3] : []
        var attempt = 0
        var slowDowns = 0
        while true {
            do {
                await ESIGate.shared.waitIfPaused()
                let (data, response) = try await BackendClient.session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw BackendError.badResponse }
                await ESIGate.shared.check(http)
                // "Slow down": wait as long as EVE says (all calls wait together), then try again – twice at most.
                if http.statusCode == 420 || http.statusCode == 429, slowDowns < 2, !Task.isCancelled {
                    let seconds = ESIGate.wait(from: http)
                    if await ESIGate.shared.pause(seconds: seconds) { await ESIGate.tellUser(seconds) }
                    slowDowns += 1
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw ESIError(status: http.statusCode, path: target.absoluteString,
                                   body: String(decoding: data, as: UTF8.self))
                }
                if let watch = ExpiryWatch.current,
                   let text = http.value(forHTTPHeaderField: "Expires"), let date = ExpiryWatch.parse(text) {
                    watch.saw(date)   // when EVE will have new data for this
                }
                return (data, http)
            } catch {
                let transient = EveDowntime.isTemporary(error)
                if transient && EveDowntime.isNow() { throw DowntimeError() }
                guard transient, attempt < delays.count, !Task.isCancelled else { throw error }
                try await Task.sleep(nanoseconds: delays[attempt] * 1_000_000_000)
                attempt += 1
            }
        }
    }

    /// esi_get – the parsed JSON (dict, list or number).
    static func get(_ endpoint: String, params: [String: String] = [:], auth: Bool = true) async throws -> Any {
        let (data, _) = try await send(endpoint, params: params, auth: auth)
        return try JSON.parse(data)
    }

    /// esi_get_all_pages – every row of a paginated endpoint (X-Pages header).
    static func getAllPages(_ endpoint: String, params: [String: String] = [:], auth: Bool = true) async throws -> [Any] {
        var query = params
        query["page"] = "1"
        let (data, response) = try await send(endpoint, params: query, auth: auth)
        // 204 No Content (e.g. a contract that has just ended) = an empty list.
        var rows: [Any] = data.isEmpty ? [] : ((try JSON.parse(data) as? [Any]) ?? [])
        let pages = Int(response.value(forHTTPHeaderField: "X-Pages") ?? "1") ?? 1
        if pages > 1 {
            for page in 2...pages {
                query["page"] = String(page)
                let (more, _) = try await send(endpoint, params: query, auth: auth)
                rows += (try JSON.parse(more) as? [Any]) ?? []
            }
        }
        return rows
    }

    static func post(_ endpoint: String, body: Any, auth: Bool = true) async throws -> Any {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await send(endpoint, auth: auth, method: "POST", body: payload)
        return try JSON.parse(data)
    }

    // MARK: - Character endpoints

    static func characterSkills() async throws -> Any {
        let cid = try await EveAuth.shared.characterID()
        return try await get("characters/\(cid)/skills/")
    }

    static func characterSkillqueue() async throws -> Any {
        let cid = try await EveAuth.shared.characterID()
        return try await get("characters/\(cid)/skillqueue/")
    }

    /// All blueprints (originals + copies). quantity -1 = BPO, -2 = BPC; runs -1 = infinite.
    static func characterBlueprints() async throws -> [JSONDict] {
        let cid = try await EveAuth.shared.characterID()
        return asDicts(try await getAllPages("characters/\(cid)/blueprints/"))
    }

    static func characterIndustryJobs(includeCompleted: Bool = false) async throws -> Any {
        let cid = try await EveAuth.shared.characterID()
        return try await get("characters/\(cid)/industry/jobs/",
                             params: ["include_completed": includeCompleted ? "true" : "false"])
    }

    // MARK: - Assets (cached) / location names

    struct Assets {
        let byItem: [Int: JSONDict]
        let names: [Int: String]
    }

    /// _get_assets – every asset by item id plus custom names, cached for 10 minutes.
    static func getAssets() async throws -> Assets {
        try await ESIState.shared.assets()
    }

    static func isStation(_ id: Int) -> Bool { (60_000_000..<64_000_000).contains(id) }
    static func isSystem(_ id: Int) -> Bool { (30_000_000..<33_000_000).contains(id) }

    /// Public /universe/names/. Fails as a whole if any id is invalid, so retry singly.
    static func universeNames(_ ids: [Int]) async -> [Int: String] {
        var result: [Int: String] = [:]
        func add(_ response: Any) {
            for entry in asDicts(response) {
                if let id = entry.int("id"), let name = entry.string("name") { result[id] = name }
            }
        }
        for chunk in Array(Set(ids)).chunked(1000) {
            if let response = try? await post("universe/names/", body: chunk, auth: false) {
                add(response)
            } else {
                for single in chunk {
                    if let response = try? await post("universe/names/", body: [single], auth: false) {
                        add(response)
                    }
                }
            }
        }
        return result
    }

    static func typeName(_ typeID: Int) async -> String {
        await ESIState.shared.typeName(typeID)
    }

    /// _place_name – name of a station, player structure or solar system.
    static func placeName(_ locationID: Int) async -> String {
        await ESIState.shared.placeName(locationID)
    }

    /// resolve_locations – {"<id>": {name, station, container}}; walks containers up to the station.
    static func resolveLocations(_ locationIDs: [Int]) async -> JSONDict {
        var assets: Assets?
        var result: JSONDict = [:]

        for locationID in Set(locationIDs) {
            var path: [String] = []
            var current = locationID

            for _ in 0..<5 {
                if isStation(current) || isSystem(current) { break }
                if assets == nil {
                    assets = (try? await getAssets()) ?? Assets(byItem: [:], names: [:])
                }
                guard let item = assets?.byItem[current] else { break } // not ours → structure
                let label: String
                if let custom = assets?.names[current] {
                    label = custom
                } else {
                    label = await typeName(item.int("type_id") ?? 0)
                }
                path.insert(label, at: 0)
                current = item.int("location_id") ?? 0
            }

            let place = await placeName(current)
            let container: String? = path.isEmpty ? nil : path.joined(separator: " › ")
            result[String(locationID)] = [
                "name": container.map { "\(place) › \($0)" } ?? place,
                "station": place,
                "container": container as Any,
            ] as JSONDict
        }
        return result
    }
}

/// Module-level caches of esi.py (_asset_cache, _location_cache, _type_name_cache).
actor ESIState {
    static let shared = ESIState()
    private static let assetTTL: TimeInterval = 600

    private var assetsAt: Date?
    private var assetCache = ESI.Assets(byItem: [:], names: [:])
    private var locationCache: [Int: String] = [:]
    private var typeNameCache: [Int: String] = [:]

    func reset() {
        assetsAt = nil
        assetCache = ESI.Assets(byItem: [:], names: [:])
        locationCache = [:]
    }

    func assets() async throws -> ESI.Assets {
        if let at = assetsAt, Date().timeIntervalSince(at) < Self.assetTTL, !assetCache.byItem.isEmpty {
            return assetCache
        }
        let cid = try await EveAuth.shared.characterID()
        let rows = asDicts(try await ESI.getAllPages("characters/\(cid)/assets/"))
        var byItem: [Int: JSONDict] = [:]
        for row in rows {
            if let id = row.int("item_id") { byItem[id] = row }
        }

        // Custom names only exist for singleton (assembled) items like containers and ships.
        let singletons = rows.filter { $0.bool("is_singleton") }.compactMap { $0.int("item_id") }
        var names: [Int: String] = [:]
        for chunk in singletons.chunked(1000) {
            guard let response = try? await ESI.post("characters/\(cid)/assets/names/", body: chunk) else { continue }
            for entry in asDicts(response) {
                if let id = entry.int("item_id"), let name = entry.string("name"), !name.isEmpty, name != "None" {
                    names[id] = name
                }
            }
        }

        assetCache = ESI.Assets(byItem: byItem, names: names)
        assetsAt = Date()
        return assetCache
    }

    func typeName(_ typeID: Int) async -> String {
        if typeNameCache[typeID] == nil {
            let resolved = await ESI.universeNames([typeID])
            typeNameCache.merge(resolved) { _, new in new }
        }
        return typeNameCache[typeID] ?? "Type \(typeID)"
    }

    func placeName(_ locationID: Int) async -> String {
        if let cached = locationCache[locationID] { return cached }

        var name: String?
        if ESI.isStation(locationID) || ESI.isSystem(locationID) {
            name = await ESI.universeNames([locationID])[locationID]
        } else if locationID >= 1_000_000_000_000 {
            if let structure = try? await ESI.get("universe/structures/\(locationID)/") as? JSONDict {
                name = structure.string("name")
            } else {
                name = "Structure \(locationID) (no docking access)"
            }
        }

        let result = name ?? "Unknown location \(locationID)"
        locationCache[locationID] = result
        return result
    }
}
