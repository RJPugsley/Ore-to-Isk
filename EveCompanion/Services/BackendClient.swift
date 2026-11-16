import Foundation

enum BackendError: LocalizedError {
    case badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "The backend returned an unexpected response."
        case let .http(code, detail):
            // 503 = "come back shortly" (EVE downtime, static data being prepared) – just say why.
            return code == 503 ? detail : "HTTP \(code): \(detail)"
        }
    }
}

/// The app's data layer. Every request is answered in-process by the Swift engine
/// (Services/Engine/NativeBackend.swift) – same paths and JSON as before,
/// decoded into the app's models.
struct BackendClient {

    // MARK: - Endpoints

    func health() async throws {
        struct Health: Decodable { let status: String }
        _ = try await get("health", as: Health.self)
    }

    func characterID() async throws -> Int {
        try await get("character", as: CharacterIDResponse.self).characterId
    }

    func skills() async throws -> SkillsResponse {
        try await get("esi/skills", as: SkillsResponse.self)
    }

    func skillQueue() async throws -> [SkillQueueEntry] {
        try await get("esi/skillqueue", as: [SkillQueueEntry].self)
    }

    func blueprints() async throws -> [Blueprint] {
        try await get("esi/blueprints", as: [Blueprint].self)
    }

    func industryJobs() async throws -> [IndustryJob] {
        try await get("esi/industry/jobs", as: [IndustryJob].self)
    }

    /// Resolves station / structure / container ids to names (walks containers via assets).
    func locations(ids: [Int]) async throws -> [Int: LocationInfo] {
        guard !ids.isEmpty else { return [:] }
        let raw = try await post("esi/locations", body: ids, as: [String: LocationInfo].self)
        var result: [Int: LocationInfo] = [:]
        for (key, value) in raw {
            if let id = Int(key) { result[id] = value }
        }
        return result
    }

    // MARK: - Static data & manufacturing

    func sdeStatus() async throws -> SDEStatus {
        try await get("sde/status", as: SDEStatus.self)
    }

    func updateSDE(force: Bool = false) async throws -> SDEStatus {
        try await post("sde/update", query: [URLQueryItem(name: "force", value: String(force))],
                       body: [Int](), as: SDEStatus.self)
    }

    func myProducts() async throws -> [ProductOption] {
        try await get("industry/my-products", as: [ProductOption].self)
    }

    /// Everything buildable in a category / group (for browsing without typing).
    func productsInGroup(category: String, group: String) async throws -> [ProductOption] {
        try await get("industry/products-in-group",
                      query: [URLQueryItem(name: "category", value: category), URLQueryItem(name: "group", value: group)],
                      as: [ProductOption].self)
    }

    func searchProducts(_ text: String) async throws -> [ProductOption] {
        try await get("industry/products", query: [URLQueryItem(name: "search", value: text)],
                      as: [ProductOption].self)
    }

    func searchSystems(_ text: String) async throws -> [SolarSystem] {
        try await get("industry/systems", query: [URLQueryItem(name: "search", value: text)],
                      as: [SolarSystem].self)
    }

    func stockLocations() async throws -> [StockLocation] {
        try await get("industry/stock-locations", as: [StockLocation].self)
    }

    func myOrders(fresh: Bool) async throws -> MyOrdersSummary {
        try await get("market/my-orders", query: [URLQueryItem(name: "fresh", value: fresh ? "true" : "false")],
                      as: MyOrdersSummary.self)
    }

    func finances(oreHub: String) async throws -> FinanceSummary {
        try await get("finances/summary", query: [URLQueryItem(name: "ore_hub", value: oreHub)], as: FinanceSummary.self)
    }

    func skillCatalog() async throws -> [SkillCatalogEntry] {
        try await get("sde/skills", as: [SkillCatalogEntry].self)
    }

    func characterSummary() async throws -> CharacterSummary {
        try await get("character/summary", as: CharacterSummary.self)
    }

    func blueprintCategories() async throws -> [BlueprintCategory] {
        try await get("reference/blueprint-categories", as: [BlueprintCategory].self)
    }

    func buildVsSell(_ query: [URLQueryItem]) async throws -> BuildVsSellResult {
        try await get("reference/build-vs-sell", query: query, as: BuildVsSellResult.self)
    }

    func oreCatalog(_ query: [URLQueryItem] = []) async throws -> [OreCatalogEntry] {
        try await get("reprocessing/ores", query: query, as: [OreCatalogEntry].self)
    }

    func reprocessingSummary(_ query: [URLQueryItem]) async throws -> ReproSummary {
        try await get("reprocessing/summary", query: query, as: ReproSummary.self)
    }

    func calculate(_ query: [URLQueryItem]) async throws -> CalcResult {
        try await get("industry/calculate", query: query, as: CalcResult.self)
    }

    func blueprintPayback(_ query: [URLQueryItem]) async throws -> BlueprintPaybackResult {
        try await get("reference/blueprint-payback", query: query, as: BlueprintPaybackResult.self)
    }

    // MARK: - Market browser

    func marketGroups() async throws -> [MarketGroupRow] {
        try await get("market/groups", as: [MarketGroupRow].self)
    }

    func marketTypes(group: Int) async throws -> [MarketTypeRow] {
        try await get("market/types", query: [URLQueryItem(name: "group", value: String(group))], as: [MarketTypeRow].self)
    }

    func marketSearch(_ text: String) async throws -> [MarketTypeRow] {
        try await get("market/search", query: [URLQueryItem(name: "q", value: text)], as: [MarketTypeRow].self)
    }

    func marketNames(_ ids: [Int]) async throws -> [MarketTypeRow] {
        try await get("market/names", query: [URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ","))],
                      as: [MarketTypeRow].self)
    }

    func haulRoute(from: Int, to: Int, via: [Int], mode: String, avoid: [Int], maxExtra: Int,
                   penalty: Int, avoidPodKills: Bool, preference: String, quick: Bool = false) async throws -> HaulRoutePlan {
        try await get("haul/route", query: [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "to", value: String(to)),
            URLQueryItem(name: "via", value: via.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "avoid", value: avoid.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "max_extra", value: String(maxExtra)),
            URLQueryItem(name: "penalty", value: String(penalty)),
            URLQueryItem(name: "avoid_pod_kills", value: avoidPodKills ? "true" : "false"),
            URLQueryItem(name: "preference", value: preference),
            URLQueryItem(name: "quick", value: quick ? "true" : "false"),
        ], as: HaulRoutePlan.self)
    }

    struct OptimisedStops: Decodable {
        let via: [Int]
        let jumpsBefore: Int?
        let jumpsAfter: Int?
    }

    func optimiseStops(from: Int, to: Int, via: [Int], preference: String, penalty: Int, avoid: [Int]) async throws -> OptimisedStops {
        try await get("haul/optimise", query: [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "to", value: String(to)),
            URLQueryItem(name: "via", value: via.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "avoid", value: avoid.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "preference", value: preference),
            URLQueryItem(name: "penalty", value: String(penalty)),
        ], as: OptimisedStops.self)
    }

    // MARK: In-game windows / waypoints (right-click menus)

    func openInGame(_ id: Int, market: Bool) async throws {
        struct Result: Decodable { let ok: Bool }
        _ = try await post("ui/open", query: [URLQueryItem(name: "id", value: String(id)),
                                              URLQueryItem(name: "kind", value: market ? "market" : "info")],
                           body: [Int](), as: Result.self)
    }

    func waypoint(_ id: Int, clear: Bool) async throws {
        struct Result: Decodable { let ok: Bool }
        _ = try await post("ui/waypoint", query: [URLQueryItem(name: "id", value: String(id)),
                                                  URLQueryItem(name: "clear", value: clear ? "true" : "false")],
                           body: [Int](), as: Result.self)
    }

    /// product type id → blueprint type id
    func blueprintMap() async throws -> [Int: Int] {
        let pairs = try await get("reference/blueprint-map", as: [[Int]].self)
        var map: [Int: Int] = [:]
        for pair in pairs where pair.count == 2 { map[pair[0]] = pair[1] }
        return map
    }

    // MARK: Watch List

    func watchSummary(quick: Bool, fresh: Bool = false) async throws -> WatchSummary {
        try await get("watch/summary", query: [URLQueryItem(name: "quick", value: quick ? "true" : "false"),
                                               URLQueryItem(name: "fresh", value: fresh ? "true" : "false")],
                      as: WatchSummary.self)
    }

    /// The background check for notifications – no "Updating…" popup for it.
    func watchSummaryInBackground() async throws -> WatchSummary {
        let data = try await NativeBackend.handle(method: "GET", path: "watch/summary",
                                                  query: [URLQueryItem(name: "quick", value: "false"),
                                                          URLQueryItem(name: "fresh", value: "true")], body: nil)
        return try Self.decoder.decode(WatchSummary.self, from: data)
    }

    func addWatchRoute(name: String, from: Int, to: Int, via: String, avoid: String, kind: String = "mine") async throws {
        struct Result: Decodable { let ok: Bool }
        _ = try await post("watch/route", query: [
            URLQueryItem(name: "name", value: name), URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "to", value: String(to)), URLQueryItem(name: "via", value: via),
            URLQueryItem(name: "avoid", value: avoid), URLQueryItem(name: "kind", value: kind),
        ], body: [Int](), as: Result.self)
    }

    func deleteWatchRoute(id: Int) async throws {
        struct Result: Decodable { let ok: Bool }
        _ = try await post("watch/route/delete", query: [URLQueryItem(name: "id", value: String(id))], body: [Int](), as: Result.self)
    }

    func renameWatchRoute(id: Int, name: String) async throws {
        struct Result: Decodable { let ok: Bool }
        _ = try await post("watch/route/rename", query: [URLQueryItem(name: "id", value: String(id)),
                                                         URLQueryItem(name: "name", value: name)], body: [Int](), as: Result.self)
    }

    func currentPlace() async throws -> RoutePlace {
        try await get("haul/here", as: RoutePlace.self)
    }

    func searchPlaces(_ text: String) async -> RoutePlaceSearch {
        (try? await get("haul/places", query: [URLQueryItem(name: "q", value: text)], as: RoutePlaceSearch.self))
            ?? RoutePlaceSearch(places: [], canSearchStructures: true)
    }

    /// Returns how many waypoints were set.
    func sendRoute(path: [Int], anchors: [(index: Int, location: Int)], preference: String, destinationOnly: Bool,
                   everySystem: Bool = false, penalty: Int = 50, gameAvoid: [Int] = [],
                   gameAvoidsPodKills: Bool = false) async throws -> Int {
        struct Result: Decodable { let sent: Int }
        let result = try await post("haul/waypoints", query: [
            URLQueryItem(name: "path", value: path.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "anchors", value: anchors.map { "\($0.index):\($0.location)" }.joined(separator: ",")),
            URLQueryItem(name: "preference", value: preference),
            URLQueryItem(name: "destination_only", value: destinationOnly ? "true" : "false"),
            URLQueryItem(name: "every_system", value: everySystem ? "true" : "false"),
            URLQueryItem(name: "penalty", value: String(penalty)),
            URLQueryItem(name: "game_avoid", value: gameAvoid.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "game_avoids_pod_kills", value: gameAvoidsPodKills ? "true" : "false"),
        ], body: [Int](), as: Result.self)
        return result.sent
    }

    func haulShips() async throws -> [HaulShip] {
        try await get("haul/ships", as: [HaulShip].self)
    }

    func haulPlan(start: Int, hub: String, cargo: Double, excluded: Set<Int>, warnValue: Double) async throws -> HaulPlan {
        try await get("haul/plan", query: [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "hub", value: hub),
            URLQueryItem(name: "cargo", value: String(cargo)),
            URLQueryItem(name: "exclude", value: excluded.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "warn_value", value: String(warnValue)),
        ], as: HaulPlan.self)
    }

    func marketItem(typeID: Int, scope: String, referenceHub: String) async throws -> MarketItemDetail {
        try await get("market/item", query: [URLQueryItem(name: "type_id", value: String(typeID)),
                                             URLQueryItem(name: "scope", value: scope),
                                             URLQueryItem(name: "reference_hub", value: referenceHub)],
                      as: MarketItemDetail.self)
    }

    /// Base materials (one run, ME 0) for each blueprint type, keyed by blueprint type id.
    func baseMaterials(_ blueprintIDs: [Int]) async -> [Int: [MaterialNeed]] {
        guard !blueprintIDs.isEmpty else { return [:] }
        let ids = blueprintIDs.map(String.init).joined(separator: ",")
        let raw = (try? await get("reference/materials", query: [URLQueryItem(name: "ids", value: ids)],
                                  as: [String: [MaterialNeed]].self)) ?? [:]
        var result: [Int: [MaterialNeed]] = [:]
        for (key, value) in raw { if let id = Int(key) { result[id] = value } }
        return result
    }

    /// Predictive search: buildable item names matching `text` (best matches first).
    func suggestBuildable(_ text: String, category: String = "", group: String = "") async -> [String] {
        let query = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "category", value: category),
                     URLQueryItem(name: "group", value: group)]
        return (try? await get("reference/suggest", query: query, as: [String].self)) ?? []
    }

    func blueprintCopying(_ query: [URLQueryItem]) async throws -> CopyingResult {
        try await get("build/copying", query: query, as: CopyingResult.self)
    }

    // MARK: - Mining

    func miningLedger(hub: String) async throws -> MiningLedger {
        try await get("mining/ledger", query: [URLQueryItem(name: "hub", value: hub)], as: MiningLedger.self)
    }

    func buildPlan(_ query: [URLQueryItem]) async throws -> BuildPlan {
        try await get("build/plan", query: query, as: BuildPlan.self)
    }

    // MARK: - History

    func syncHistory(force: Bool = false) async throws {
        struct Result: Decodable { let errors: [String] }
        _ = try await get("history/sync", query: [URLQueryItem(name: "force", value: force ? "true" : "false")], as: Result.self)
    }

    func trackRecord(productTypeID: Int) async throws -> TrackRecord {
        try await get("history/track-record", query: [URLQueryItem(name: "product_type_id", value: String(productTypeID))],
                      as: TrackRecord.self)
    }

    func orderResults() async throws -> OrderResults {
        try await get("history/order-results", as: OrderResults.self)
    }

    func completedJobs() async throws -> CompletedJobs {
        try await get("history/jobs", as: CompletedJobs.self)
    }

    func netWorthHistory() async throws -> [NetWorthPoint] {
        try await get("history/net-worth", as: [NetWorthPoint].self)
    }

    func watchlist() async throws -> [Int] {
        try await get("history/watchlist", as: [Int].self)
    }

    func setWatch(typeID: Int, on: Bool) async throws {
        struct Result: Decodable { let watched: Bool }
        _ = try await post("history/watch", query: [URLQueryItem(name: "type_id", value: String(typeID)),
                                                    URLQueryItem(name: "on", value: on ? "true" : "false")],
                           body: [Int](), as: Result.self)
    }

    // MARK: - Plumbing

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let ticket = await Self.track("GET", path, query)
        do {
            let data = try await NativeBackend.handle(method: "GET", path: path, query: query, body: nil)
            await Self.done(ticket)
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            await Self.done(ticket)
            throw error
        }
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: B, as type: T.Type) async throws -> T {
        let payload = try JSONEncoder().encode(body)
        let ticket = await Self.track("POST", path, query)
        do {
            let data = try await NativeBackend.handle(method: "POST", path: path, query: query, body: payload)
            await Self.done(ticket)
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            await Self.done(ticket)
            throw error
        }
    }

    // MARK: - The "Updating…" popup (Views/ActivityPopup.swift)

    private static func track(_ method: String, _ path: String, _ query: [URLQueryItem]) async -> UUID? {
        guard let label = ActivityCenter.label(method: method, path: path, query: query) else { return nil }
        return await MainActor.run { ActivityCenter.shared.start(label) }
    }

    private static func done(_ ticket: UUID?) async {
        guard let ticket else { return }
        await MainActor.run { ActivityCenter.shared.finish(ticket) }
    }
}
