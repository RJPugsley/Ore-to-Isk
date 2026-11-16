import AppKit
import Foundation
import Observation
import UserNotifications

/// Central app state shared by every window and view.
@MainActor
@Observable
final class AppState {

    enum ConnectionState: Equatable {
        case unknown
        case checking
        case online
        case offline(String)

        var isOnline: Bool { self == .online }
    }

    // Connection / auth
    var connection: ConnectionState = .unknown
    var characterID: Int?
    var authError: String?

    // Character data
    var character: CharacterInfo?
    var corporationName: String?
    var skills: SkillsResponse?
    var skillQueue: [SkillQueueEntry] = []

    // Industry data
    var blueprints: [Blueprint] = []
    var industryJobs: [IndustryJob] = []
    var locations: [Int: LocationInfo] = [:]
    var isLoadingIndustry = false
    var industryError: String?
    var industryUpdated: Date?

    /// Resolved names for type / corporation IDs (from public ESI).
    var names: [Int: String] = [:]

    // Status
    var isLoading = false
    var lastUpdated: Date?
    var lastError: String?

    var isAuthenticated: Bool { characterID != nil }

    var backend: BackendClient { BackendClient() }

    private let publicESI = PublicESIClient()

    func name(for id: Int) -> String {
        names[id] ?? "Type \(id)"
    }

    func location(for id: Int) -> LocationInfo? {
        locations[id]
    }

    /// Blueprint item id → the active job using it.
    var jobsByBlueprint: [Int: IndustryJob] {
        Dictionary(industryJobs.map { ($0.blueprintId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Lifecycle

    /// Called once when the main window appears.
    func startup() async {
        NativeBackend.startup() // refresh CCP static data in the background if needed
        startContractWatch()
        startActivityWatch()
        startTravelWatch()
        startWatchAlerts()
        await refreshAll()
        Task { await loadMenuData() }
    }

    /// Scans copy contracts every 30 minutes while the app is open, so Blueprint Copying can
    /// spot which ones vanished before expiry (probably sold) even when that page isn't open.
    /// Every hour: CCP's kills and jumps per system into history, so the Route page's 24 h / 7 d
    /// figures build up from the app's own records.
    private func startActivityWatch() {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await NativeBackend.recordSystemActivity()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Every 30 s: where you are – a dock somewhere new counts a trip (Watch List regular routes).
    private func startTravelWatch() {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await NativeBackend.checkTravel()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: - Watch List notifications (only while the app is running)

    /// Last seen state per watched route / place: light and haulers ganked there in 24 h.
    @ObservationIgnored private var watchSeen: [String: (light: String, haulers: Int)] = [:]
    @ObservationIgnored private var watchBaseline = false

    static let watchNotifyKey = "watch.notify"

    static var watchNotificationsOn: Bool {
        UserDefaults.standard.object(forKey: watchNotifyKey) == nil ? true : UserDefaults.standard.bool(forKey: watchNotifyKey)
    }

    /// Every 15 minutes: check watched routes and places; notify when one turns red or a hauler is ganked there.
    private func startWatchAlerts() {
        Task {
            try? await Task.sleep(for: .seconds(180))
            while !Task.isCancelled {
                if Self.watchNotificationsOn, isAuthenticated, let summary = try? await backend.watchSummaryInBackground() {
                    checkWatchAlerts(summary)
                }
                try? await Task.sleep(for: .seconds(900))
            }
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkWatchAlerts(_ summary: WatchSummary) {
        var alerts: [(String, String)] = []
        func look(_ key: String, _ name: String, light: String, haulers: Int, worst: String?) {
            if light == "pending" { return }
            let before = watchSeen[key]
            watchSeen[key] = (light, haulers)
            guard watchBaseline, let before else { return }
            if haulers > before.haulers {
                alerts.append(("Hauler ganked – \(name)", "\(haulers - before.haulers) more hauler\(haulers - before.haulers == 1 ? "" : "s") ganked in the last 24 h" + (worst.map { " · \($0)" } ?? "")))
            } else if light == "red" && before.light != "red" {
                alerts.append(("Red – \(name)", worst ?? "Watch out on this route"))
            }
        }
        for route in summary.routes {
            let worst = [route.worstSystem, route.worstReason].compactMap { $0 }.joined(separator: ": ")
            look(route.key, route.name, light: route.worst, haulers: route.haulerGanksDay, worst: worst.isEmpty ? nil : worst)
        }
        for place in summary.places {
            look(place.key, place.name, light: place.row.light, haulers: place.row.haulerGanksDayCounting ?? 0,
                 worst: place.row.reasons.first)
        }
        watchBaseline = true
        guard !alerts.isEmpty else { return }
        requestNotificationPermission()
        for (title, body) in alerts.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - Page navigation from inside pages (e.g. Watch List → Route)

    /// Set to switch the window to a page (ContentView picks it up and clears it).
    var goToPage: SidebarItem?

    // MARK: - Right-click menus (Views/ContextMenus.swift)

    /// Which items can be built: product type id → blueprint type id.
    var blueprintForProduct: [Int: Int] = [:]
    /// Your Market Watchlist.
    var watchedTypes: Set<Int> = []

    /// What a page should show when it's opened from a menu elsewhere (it clears this when done).
    enum PageIntent: Equatable {
        case manufacturing(blueprintTypeID: Int, name: String)
        case buildVsSell(name: String)
        case payback(name: String)
    }
    var intent: PageIntent?

    /// The product a blueprint builds (from the same map).
    func product(ofBlueprint blueprint: Int) -> Int? {
        blueprintForProduct.first { $0.value == blueprint }?.key
    }

    func loadMenuData() async {
        if let map = try? await backend.blueprintMap() { blueprintForProduct = map }
        if let watched = try? await backend.watchlist() { watchedTypes = Set(watched) }
    }

    private func flash(_ text: String) { ActivityCenter.shared.flash(text) }

    func showInMarket(_ typeID: Int) {
        UserDefaults.standard.set(typeID, forKey: "market.typeId")
        goToPage = .market
    }

    func open(_ intent: PageIntent) {
        self.intent = intent
        switch intent {
        case .manufacturing: goToPage = .manufacturing
        case .buildVsSell: goToPage = .buildVsSell
        case .payback: goToPage = .blueprintPayback
        }
    }

    func addToBuildPlanner(blueprintTypeID: Int, name: String, runs: Int = 1) {
        let d = UserDefaults.standard
        var items = (d.string(forKey: "buildPlanner.items") ?? "").split(separator: ",").map(String.init)
        if let index = items.firstIndex(where: { $0.hasPrefix("\(blueprintTypeID):") }) {
            let current = Int(items[index].split(separator: ":").last ?? "") ?? 0
            items[index] = "\(blueprintTypeID):\(current + runs)"
        } else {
            items.append("\(blueprintTypeID):\(runs)")
        }
        d.set(items.joined(separator: ","), forKey: "buildPlanner.items")
        flash("\(name) added to the Build Planner ✓")
    }

    func toggleWatch(_ typeID: Int, name: String) {
        let on = !watchedTypes.contains(typeID)
        if on { watchedTypes.insert(typeID) } else { watchedTypes.remove(typeID) }
        Task {
            do {
                try await backend.setWatch(typeID: typeID, on: on)
                flash(on ? "\(name) added to your Market Watchlist ✓" : "\(name) removed from your Market Watchlist")
            } catch {
                if on { watchedTypes.remove(typeID) } else { watchedTypes.insert(typeID) }
                flash(error.localizedDescription)
            }
        }
    }

    func showInGame(_ id: Int, market: Bool, name: String) {
        Task {
            do {
                try await backend.openInGame(id, market: market)
                flash((market ? "Market for \(name)" : "Info for \(name)") + " opened in game ✓")
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    func setDestination(_ id: Int, name: String, clear: Bool) {
        Task {
            do {
                try await backend.waypoint(id, clear: clear)
                flash(clear ? "Destination set in game: \(name) ✓" : "Waypoint added in game: \(name) ✓")
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    /// Route page: start here / end here (and go there).
    func routeFrom(_ id: Int, name: String) {
        let d = UserDefaults.standard
        d.set(id, forKey: "route.fromId")
        d.set(name, forKey: "route.fromName")
        d.set(true, forKey: "route.skipAutoLocation")
        goToPage = .haulRoute
    }

    func routeTo(_ id: Int, name: String) {
        let d = UserDefaults.standard
        d.set(id, forKey: "route.toId")
        d.set(name, forKey: "route.toName")
        goToPage = .haulRoute
    }

    func addStop(_ id: Int, name: String) {
        appendRouteList("route.via", id: id, name: name)
        flash("\(name) added as a stop on the Route page ✓")
    }

    func avoidSystem(_ id: Int, name: String) {
        appendRouteList("route.avoid", id: id, name: name)
        flash("Avoiding \(name) on the Route page ✓")
    }

    private func appendRouteList(_ key: String, id: Int, name: String) {
        let d = UserDefaults.standard
        var parts = (d.string(forKey: key) ?? "").split(separator: ",").map(String.init)
        guard !parts.contains(where: { $0.hasPrefix("\(id)|") }) else { return }
        parts.append("\(id)|\(name.replacingOccurrences(of: ",", with: " "))")
        d.set(parts.joined(separator: ","), forKey: key)
    }

    private func startContractWatch() {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(120))   // let startup finish first
            while !Task.isCancelled {
                let hub = UserDefaults.standard.string(forKey: "copying.hub") ?? "Jita"
                await NativeBackend.watchCopyContracts(hub: hub)
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    // MARK: - Actions

    /// EVE SSO login in the browser; the app catches the callback on localhost:29170.
    func openLogin() {
        Task {
            do {
                _ = try await SSOLogin.logIn()
                authError = nil
                await NativeBackend.resetCaches()
                await refreshAll()
            } catch AuthError.cancelled {
                // nothing to do
            } catch {
                authError = error.localizedDescription
                lastError = error.localizedDescription
            }
        }
    }

    /// Deletes the EVE tokens from the Keychain.
    func logOut() async {
        await EveAuth.shared.logOut()
        await NativeBackend.resetCaches()
        characterID = nil
        character = nil
        skills = nil
        skillQueue = []
        blueprints = []
        industryJobs = []
        locations = [:]
        await refreshAll()
    }

    /// Checks the backend, then loads character, skills and queue.
    func refreshAll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        lastError = nil
        connection = .checking

        do {
            try await backend.health()
            connection = .online
        } catch {
            connection = .offline(error.localizedDescription)
            return
        }

        do {
            characterID = try await backend.characterID()
            authError = nil
        } catch {
            characterID = nil
            authError = error.localizedDescription
            return
        }

        guard let id = characterID else { return }

        // Save anything new into the local history (journal, trades, mining, orders, jobs, net worth).
        let historyClient = backend
        Task.detached(priority: .utility) { try? await historyClient.syncHistory() }

        // Copy value-type clients so the parallel child tasks don't touch main-actor state.
        let esi = publicESI
        let client = backend

        do {
            async let infoTask = esi.characterInfo(id: id)
            async let skillsTask = client.skills()
            async let queueTask = client.skillQueue()

            let (info, skillsResult, queueResult) = try await (infoTask, skillsTask, queueTask)
            character = info
            skills = skillsResult
            skillQueue = queueResult.sorted { $0.queuePosition < $1.queuePosition }

            await resolveNames(corporationID: info.corporationId)
            lastUpdated = Date()
        } catch {
            lastError = error.localizedDescription
        }

        await loadIndustry()
    }

    /// Blueprints, active industry jobs and the names of where they are.
    func loadIndustry() async {
        guard isAuthenticated, !isLoadingIndustry else { return }
        isLoadingIndustry = true
        defer { isLoadingIndustry = false }

        let client = backend
        do {
            async let blueprintsTask = client.blueprints()
            async let jobsTask = client.industryJobs()
            let (newBlueprints, newJobs) = try await (blueprintsTask, jobsTask)
            blueprints = newBlueprints
            industryJobs = newJobs.sorted { $0.endDate < $1.endDate }
            industryError = nil
        } catch {
            industryError = error.localizedDescription
            return
        }

        // Type names for blueprints and job products.
        var typeIDs = Set(blueprints.map(\.typeId))
        for job in industryJobs {
            typeIDs.insert(job.blueprintTypeId)
            if let product = job.productTypeId { typeIDs.insert(product) }
        }
        let missingTypes = typeIDs.subtracting(names.keys)
        if !missingTypes.isEmpty {
            if let resolved = try? await publicESI.names(for: Array(missingTypes)) {
                names.merge(resolved) { _, new in new }
            }
        }

        // Location names (backend walks containers → station / structure).
        let locationIDs = Set(blueprints.map(\.locationId) + industryJobs.map(\.facilityId))
        let missingLocations = locationIDs.subtracting(locations.keys)
        if !missingLocations.isEmpty {
            do {
                let resolved = try await client.locations(ids: Array(missingLocations))
                locations.merge(resolved) { _, new in new }
            } catch {
                industryError = "Could not resolve locations: \(error.localizedDescription)"
            }
        }

        industryUpdated = Date()
    }

    private func resolveNames(corporationID: Int) async {
        var ids = Set<Int>()
        ids.insert(corporationID)
        skills?.skills.forEach { ids.insert($0.skillId) }
        skillQueue.forEach { ids.insert($0.skillId) }

        let missing = ids.subtracting(names.keys)
        if !missing.isEmpty {
            do {
                let resolved = try await publicESI.names(for: Array(missing))
                names.merge(resolved) { _, new in new }
            } catch {
                lastError = "Could not resolve names: \(error.localizedDescription)"
            }
        }
        corporationName = names[corporationID]
    }
}
