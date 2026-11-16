import SwiftUI
import AppKit

// MARK: - Models (/haul/route)

struct RouteGank: Decodable {
    let time: Double
    let ship: String
    let value: Double

    var text: String {
        let date = Date(timeIntervalSince1970: time)
        return "\(ship) (\(value.short)) \(date.formatted(.relative(presentation: .named)))"
    }
}

struct RouteSystem: Decodable, Identifiable {
    let systemId: Int
    let name: String
    let region: String?
    let security: Double
    /// "endpoint" (start / end – station kills count too) or "transit" (only gate kills count).
    let role: String
    let jumpsHour: Int?
    let killsHour: Int
    let killsHourCapped: Bool
    let podsHour: Int
    let killsDay: Int?
    let killsDayCapped: Bool
    let killsDayCcp: Bool
    let killsWeek: Int?
    let killsWeekCapped: Bool
    let killsWeekCcp: Bool
    /// "gates n · station/undock n · belts & sites n"
    let splitHour: String
    let splitDay: String
    let splitWeek: String
    /// Kills that count here, per 1,000 ships passing through in a day.
    let perThousand: Double?
    /// This system's usual kills that count, per day (its last 7 days ÷ 7).
    let normalDay: Double
    /// Ships CONCORD destroyed here this week – the gankers' side of each gank (and other criminals).
    let concordKillsWeek: Int?
    /// "players" = kills by players (zKillboard) · "ccp" = zKillboard didn't answer.
    let killsFrom: String
    let ccpHour: Int
    let ccpDay: Int
    let ccpDayHours: Int
    let ccpWeek: Int
    let ccpWeekHours: Int
    let ganksWeek: Int
    let ganksDay: Int
    let haulerGanksWeek: Int
    /// Haulers ganked where you'd be (gates / your undock) in the last 24 h – for Watch List alerts.
    let haulerGanksDayCounting: Int?
    let gankSplitWeek: String
    let lastGank: RouteGank?
    let zkillOk: Bool
    /// The quick first look: route and CCP's figures only, kills still coming.
    let pending: Bool?
    let light: String
    let reasons: [String]

    var fromCCP: Bool { killsFrom == "ccp" }
    /// Start or end of the route ("dock" = a station / structure was picked there).
    var isEndpoint: Bool { role != "transit" }

    /// "12", "200+" (zKillboard's limit reached), "57*" (CCP's count), "–" (not known yet).
    static func countText(_ value: Int?, capped: Bool, ccp: Bool) -> String {
        guard let value else { return "–" }
        return value.short + (capped ? "+" : "") + (ccp ? "*" : "")
    }

    /// Tooltip for a kill column: what's counted, where it happened, and CCP's all-losses figure.
    func killsHelp(_ frame: String, split: String, capped: Bool, usedCCP: Bool, ccp: Int, hours: Int?) -> String {
        var text: String
        if fromCCP {
            text = "zKillboard didn't answer – CCP's count of every player ship lost (including to NPCs and CONCORD)."
        } else if usedCCP {
            text = "Busier than zKillboard's 200-kill limit, so this is CCP's count less the criminals CONCORD destroyed."
        } else {
            text = "Ships killed by players in the \(frame). Losses to NPCs only – rats, or CONCORD killing a ganker – aren't counted."
            if capped { text += "\nzKillboard sends at most 200 kills, so there were at least this many." }
        }
        if !fromCCP { text += "\nWhere: " + split + "." }
        text += "\n" + (role == "dock" ? "Start / end of the route: gate kills and kills at your station's undock count for the light."
                         : isEndpoint ? "Start / end of the route: gate and station kills count for the light."
                                    : "Passing through: only gate kills count for the light.")
        if let hours { text += "\nCCP: \(ccp) player ship(s) lost over the \(hours) hour(s) of this period the app has recorded." }
        else { text += "\nCCP: \(ccp) player ship(s) lost." }
        return text
    }

    var dayHelpExtra: String {
        var text = "\nUsually about \(String(format: "%.1f", normalDay)) a day that count."
        if let perThousand { text += "\n\(String(format: "%.1f", perThousand)) per 1,000 ships passing through." }
        return text
    }

    var id: Int { systemId }

    /// Security as the game shows it (0.45 → 0.5; anything just above 0 shows 0.1).
    var securityText: String { RouteSystem.securityText(security) }

    static func securityText(_ sec: Double) -> String {
        if sec > 0 && sec < 0.05 { return "0.1" }
        return String(format: "%.1f", (sec * 10).rounded() / 10)
    }

    static func securityColor(_ sec: Double) -> Color {
        if sec >= 0.85 { return .cyan }
        if sec >= 0.45 { return .green }
        if sec > 0 { return .orange }
        return .red
    }

    var lightColor: Color { RouteSystem.lightColor(light) }

    static func lightColor(_ light: String) -> Color {
        switch light {
        case "red": return .red
        case "amber": return .orange
        case "pending": return .gray
        default: return .green
        }
    }

    var gankHelp: String {
        guard zkillOk else { return "zKillboard couldn't be reached – ganks unknown." }
        var text = "\(ganksWeek) ship(s) ganked in the last 7 days – killed by players who CONCORD then destroyed"
        if haulerGanksWeek > 0 { text += ", \(haulerGanksWeek) of them haulers" }
        text += "."
        if let lastGank { text += "\nLatest: \(lastGank.text)." }
        text += "\nWhere: " + gankSplitWeek + "."
        if let concordKillsWeek { text += "\nCONCORD destroyed \(concordKillsWeek) criminal ship(s) here this week." }
        return text
    }
}

/// A place a route can start or end: a system, an NPC station or a player structure you can dock at.
struct RoutePlace: Decodable, Hashable {
    let locationId: Int
    let kind: String
    let name: String
    let systemId: Int
    let systemName: String
    let security: Double
    /// "System", "Station", "Trade hub", "Refinery (Athanor)", "Citadel (Astrahus)"…
    let label: String
    /// One of the five main trade hub stations (Jita 4-4, Amarr, Dodixie, Rens, Hek).
    let hub: Bool?

    var isSystem: Bool { kind == "system" }

    /// Icon for the search list: system, NPC station, trade hub or player structure.
    var icon: (String, Color) {
        if hub == true { return ("cart.circle.fill", .orange) }
        switch kind {
        case "system": return ("circle.circle", RouteSystem.securityColor(security))
        case "structure": return ("building.columns.fill", .purple)
        default: return ("building.2.fill", .secondary)
        }
    }
}

struct RoutePlaceSearch: Decodable {
    let places: [RoutePlace]
    let canSearchStructures: Bool
}

struct RouteAnchor: Decodable {
    /// Position of a start / stop / end on the path, and the station / structure / system to send for it.
    let index: Int
    let locationId: Int
}

struct HaulRoutePlan: Decodable {
    let mode: String
    let fromPlace: RoutePlace?
    let toPlace: RoutePlace?
    let viaPlaces: [RoutePlace]
    let anchors: [RouteAnchor]
    let podKillSystemsAvoided: Int?
    let jumps: Int
    let baseJumps: Int
    let detoured: [String]
    let worst: String
    let lowestSecurity: Double?
    let killsLastHour: Int
    let ganksWeek: Int
    let haulerGanksWeek: Int
    let watchingSince: Double?
    let systems: [RouteSystem]
}

// MARK: - View

/// Haul › Route: is the way there safe right now?
struct RouteView: View {
    @Environment(AppState.self) private var appState

    // Until the page reads where you are: Jita → Amarr, the two biggest hubs.
    @AppStorage("route.fromName") private var fromName = "Jita"
    @AppStorage("route.fromId") private var fromId = 30000142
    @AppStorage("route.toName") private var toName = "Amarr"
    @AppStorage("route.toId") private var toId = 30002187
    /// "game" = the route your game would fly (Autopilot settings) · "lowest_risk" = that, plus detours round red systems.
    @AppStorage("route.mode2") private var mode = "game"
    @AppStorage("route.maxExtra") private var maxExtra = 5
    /// "id|name" pairs, comma separated.
    @AppStorage("route.avoid") private var avoidText = ""
    /// Stops on the way, in order: "id|name" pairs, comma separated.
    @AppStorage("route.via") private var viaText = ""
    /// How your in-game autopilot is set – the app checks its waypoints against it.
    @AppStorage("route.autopilot") private var autopilot = "secure"
    /// The game's "Security penalty" slider (0–100, game default 50).
    @AppStorage("route.penalty") private var penalty = 50
    /// The game's "Avoid systems where pod killing has recently occurred".
    @AppStorage("route.avoidPodKills") private var avoidPodKills = false
    @State private var showAutopilot = false
    @State private var showWatchName = false
    @State private var watchName = ""
    @State private var viaAdd = ""
    @State private var lookedUpLocation = false

    @State private var fromText = ""
    @State private var toText = ""
    @State private var avoidAdd = ""
    /// Places from the last searches, by name – picking a suggestion looks it up here.
    @State private var placeCache: [String: RoutePlace] = [:]
    @State private var canSearchStructures = true
    @State private var plan: HaulRoutePlan?
    /// Which settings the shown plan is for – when they differ from the current ones, it's being replaced.
    @State private var planKey: LoadKey?
    @State private var stage = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var refreshCounter = 0
    @State private var sendStatus: String?
    @State private var selection: RouteSystem.ID?

    private struct AvoidEntry: Identifiable, Hashable {
        let id: Int
        let name: String
    }

    private var avoidList: [AvoidEntry] {
        avoidText.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: "|", maxSplits: 1)
            guard let id = parts.first.flatMap({ Int($0) }) else { return nil }
            return AvoidEntry(id: id, name: parts.count > 1 ? String(parts[1]) : String(id))
        }
    }

    private func saveAvoid(_ list: [AvoidEntry]) {
        avoidText = list.map { "\($0.id)|\($0.name)" }.joined(separator: ",")
    }

    private var viaList: [AvoidEntry] {
        viaText.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: "|", maxSplits: 1)
            guard let id = parts.first.flatMap({ Int($0) }) else { return nil }
            return AvoidEntry(id: id, name: parts.count > 1 ? String(parts[1]) : String(id))
        }
    }

    private func saveVia(_ list: [AvoidEntry]) {
        viaText = list.map { "\($0.id)|\($0.name.replacingOccurrences(of: ",", with: " "))" }.joined(separator: ",")
    }

    private struct LoadKey: Hashable {
        var from, to, maxExtra, refresh: Int
        var mode, avoid, via: String
        var penalty: Int
        var podKills: Bool
        var preference: String

        /// Same route, only the timed refresh differs.
        func sameRoute(as other: LoadKey) -> Bool {
            var a = self
            a.refresh = other.refresh
            return a == other
        }
    }

    private var loadKey: LoadKey {
        LoadKey(from: fromId, to: toId, maxExtra: maxExtra, refresh: refreshCounter, mode: mode,
                avoid: avoidList.map { String($0.id) }.joined(separator: ","),
                via: viaList.map { String($0.id) }.joined(separator: ","),
                penalty: penalty, podKills: avoidPodKills, preference: autopilot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
                .zIndex(1)
            Divider()
            if let plan {
                content(plan)
                    // The old route is faded while the new one is planned (the popup says what's happening).
                    .opacity(planKey.map { $0.sameRoute(as: loadKey) } ?? true ? 1 : 0.4)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Plan the Route", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { refreshCounter += 1 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Checking every system on the way – kills, traffic and ganks…")
                    Text("The first look reads a week of killmails, so it takes a little longer.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(plan.map { "\(fromName) → \(toName) · \($0.jumps) jumps" } ?? "")
        .onAppear {
            if fromText.isEmpty { fromText = fromName }
            if toText.isEmpty { toText = toName }
        }
        .task {
            // Start from where you are now, each time the page opens (type over it for another start).
            guard !lookedUpLocation else { return }
            lookedUpLocation = true
            // Opened from the Watch List with a route already set – keep its start.
            if UserDefaults.standard.bool(forKey: "route.skipAutoLocation") {
                UserDefaults.standard.set(false, forKey: "route.skipAutoLocation")
                return
            }
            await useMyLocation(quiet: true)
        }
        .task(id: fromText) { await resolve(fromText, isFrom: true) }
        .task(id: toText) { await resolve(toText, isFrom: false) }
        .task(id: loadKey) { await load() }
        .task {
            // Fresh numbers every 10 minutes while the page is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                refreshCounter += 1
            }
        }
    }

    // MARK: Controls

    /// Systems, stations and structures you can dock at, for the From / To boxes.
    private func suggestPlaces(_ text: String) async -> [String] {
        let found = await appState.backend.searchPlaces(text)
        canSearchStructures = found.canSearchStructures
        for place in found.places { placeCache[place.name] = place }
        return found.places.prefix(40).map(\.name)
    }

    private func suggestSystems(_ text: String) async -> [String] {
        ((try? await appState.backend.searchSystems(text)) ?? []).prefix(8).map(\.name)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("From")
                SuggestingSearchField(prompt: "System, station or structure", text: $fromText, width: 230,
                                      suggest: { await suggestPlaces($0) }, maxShown: 40, icon: { placeCache[$0]?.icon }, keepExactMatch: true)
                    .help(plan?.fromPlace.map { "\($0.label) in \($0.systemName)" } ?? "")
                Button {
                    Task { await useMyLocation() }
                } label: {
                    Image(systemName: "location.fill")
                }
                .buttonStyle(.borderless)
                .help("Start from where you are now in the game")
                Button {
                    let (name, id) = (fromName, fromId)
                    fromName = toName; fromId = toId; fromText = toName
                    toName = name; toId = id; toText = name
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Swap – plan the trip back")
                Text("To")
                SuggestingSearchField(prompt: "System, station or structure", text: $toText, width: 230,
                                      suggest: { await suggestPlaces($0) }, maxShown: 40, icon: { placeCache[$0]?.icon }, keepExactMatch: true)
                    .help(plan?.toPlace.map { "\($0.label) in \($0.systemName)" } ?? "")
                if !canSearchStructures {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Only systems can be found right now. To find stations and structures you can dock at, add esi-search.search_structures.v1 to your application at developers.eveonline.com, then log out and in again (Pilot tab).")
                }

                Picker("Route", selection: $mode) {
                    Text("Game Route").tag("game")
                    Text("Lowest Risk").tag("lowest_risk")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .help("Game Route = what your game would fly, using your Autopilot settings and the systems you avoid. Lowest Risk = the same, then goes round red systems if it's safer and costs no more than the extra jumps you allow.")

                if mode == "lowest_risk" {
                    HStack(spacing: 4) {
                        Text("Up to")
                        TextField("", value: $maxExtra, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 36)
                        Stepper("Extra jumps", value: $maxExtra, in: 0...30).labelsHidden()
                        Text("extra jumps")
                    }
                }

                Button {
                    showAutopilot.toggle()
                } label: {
                    Label("Autopilot: \(autopilotLabel)", systemImage: "gearshape")
                }
                .help("Match your in-game autopilot settings – the app plans with them and checks its waypoints against them")
                .popover(isPresented: $showAutopilot, arrowEdge: .bottom) { autopilotPanel }

                Spacer()
                PageKeyButton(columns: Self.columnKey)
                Button("Refresh") { refreshCounter += 1 }
            }
            .zIndex(2)   // the From / To lists draw over the Avoid row

            HStack(spacing: 8) {
                Text("Avoid")
                ForEach(avoidList) { entry in
                    HStack(spacing: 3) {
                        Text(entry.name)
                        Button {
                            if Confirm.delete("route.avoid", title: "Stop avoiding \(entry.name)?",
                                              message: "Routes may go through it again.", button: "Stop Avoiding") {
                                saveAvoid(avoidList.filter { $0.id != entry.id })
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.red.opacity(0.12), in: Capsule())
                }
                if avoidList.isEmpty {
                    Text("nothing – right-click a system below, or add one").font(.caption).foregroundStyle(.secondary)
                }
                SuggestingSearchField(prompt: "Add a system", text: $avoidAdd, width: 150) { await suggestSystems($0) }
                    .onSubmit { Task { await addAvoid(avoidAdd) } }
                    .onChange(of: avoidAdd) { _, text in
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            if text == avoidAdd { await addAvoid(text, exactOnly: true) }
                        }
                    }

                Spacer()
            }
            .zIndex(1)   // its list draws over the Stops row

            HStack(spacing: 8) {
                Text("Stops")
                ForEach(Array(viaList.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 3) {
                        Text("\(index + 1). \(entry.name)").lineLimit(1)
                        Button {
                            if Confirm.delete("route.stop", title: "Remove the stop at \(entry.name)?",
                                              message: "The route goes straight past it.", button: "Remove") {
                                saveVia(viaList.filter { $0.id != entry.id })
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .help("The route goes through here, in this order – sent to the game as a waypoint")
                }
                if viaList.isEmpty {
                    Text("none – the route goes straight from start to end").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Task { await optimiseStops() }
                } label: {
                    Label("Optimise Order", systemImage: "arrow.triangle.swap")
                }
                .buttonStyle(.borderless)
                .disabled(viaList.count < 2)
                .help(viaList.count < 2
                      ? "Add two or more stops, then this puts them in the order with the fewest jumps (like the game's \"Optimize route\")"
                      : "Like the game's \"Optimize route\": puts your stops in the order with the fewest jumps")
                SuggestingSearchField(prompt: "Add a stop", text: $viaAdd, width: 200,
                                      suggest: { await suggestPlaces($0) }, maxShown: 40, icon: { placeCache[$0]?.icon }, keepExactMatch: true)
                    .onSubmit { Task { await addVia(viaAdd) } }
                    .onChange(of: viaAdd) { _, text in
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            if text == viaAdd { await addVia(text, exactOnly: true) }
                        }
                    }

                Spacer()

                if let sendStatus {
                    Text(sendStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button {
                    watchName = "\(plan?.fromPlace?.systemName ?? fromName) → \(plan?.toPlace?.systemName ?? toName)"
                    showWatchName = true
                } label: {
                    Label("Watch", systemImage: "binoculars")
                }
                .disabled(plan == nil)
                .help("Add this route (start, stops, end and avoids) to the Watch List")
                .popover(isPresented: $showWatchName, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Add to the Watch List").font(.headline)
                        TextField("Name", text: $watchName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .onSubmit { Task { await watchThisRoute() } }
                        Text("e.g. \"Ore trade\" – you can rename it later on the Watch List.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Cancel") { showWatchName = false }
                            Button("Add") { Task { await watchThisRoute() } }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(14)
                }

                Menu("Send to Game") {
                    Button("Send route (start, stops and finish – plus a waypoint only where needed to keep you out of avoided or red systems)") { send(destinationOnly: false) }
                    Button("Destination only (the game picks the way)") { send(destinationOnly: true) }
                }
                .fixedSize()
                .disabled(plan == nil)
                .help("Sets the autopilot in EVE for the logged-in character. The first time, log out and in again so the app may set waypoints.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Autopilot settings (mirror the game's Route settings)

    private var autopilotLabel: String {
        let name = ["shortest": "Shorter", "insecure": "Less Secure"][autopilot] ?? "Safer"
        return autopilot == "shortest" ? name : "\(name) \(penalty)"
    }

    private var autopilotPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your in-game autopilot").font(.headline)
            Text("Set these the same as the Route settings in the game (the A menu). The app then routes exactly like your game, and knows which waypoints the game needs to stay on the plan.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Route preference", selection: $autopilot) {
                Text("Prefer Shorter").tag("shortest")
                Text("Prefer Safer").tag("secure")
                Text("Prefer Less Secure").tag("insecure")
            }
            .pickerStyle(.radioGroup)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Security penalty")
                    Spacer()
                    Text("\(penalty)").monospacedDigit()
                }
                Slider(value: Binding(get: { Double(penalty) }, set: { penalty = Int($0.rounded()) }), in: 0...100, step: 1)
                Text("How hard Safer / Less Secure stick to their kind of space (game default 50).")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Toggle("Avoid systems where pod killing has recently occurred", isOn: $avoidPodKills)
                .help("Uses CCP's pod kills from the last hour – the app avoids them when planning too.")
            Text("Systems you avoid here are kept out of the route by waypoints, so your in-game avoidance list doesn't need to match (EVE doesn't let apps read it). Anything you avoid only in game, add here too.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Also from the game: \"Optimize route\" is the Optimise Order button next to your stops; waypoints are always cleared before a new route is sent. Not available to apps: Triglavian / EDENCOM systems and jump bridges (keep those off in game). \"Autopilot active\", \"Show route path in space\" and \"Disable autopilot at each waypoint\" only work inside the game.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
    }

    // MARK: Content

    private func content(_ plan: HaulRoutePlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            tiles(plan)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            Text(sourceNote(plan))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            table(plan)
        }
    }

    private func tiles(_ plan: HaulRoutePlan) -> some View {
        let extra = plan.jumps - plan.baseJumps
        let jumpsDetail: String = plan.detoured.isEmpty
            ? "as your game would fly it (\(autopilotLabel))"
            : (extra > 0 ? "+\(extra) jumps to go round " : "goes round ") + plan.detoured.joined(separator: ", ")
        let worstText: String = ["red": "Red", "amber": "Amber"][plan.worst] ?? "Green"
        let reds = plan.systems.filter { $0.light == "red" }.map(\.name)
        let ambers = plan.systems.filter { $0.light == "amber" }.map(\.name)
        let worstDetail: String = !reds.isEmpty ? "watch " + reds.joined(separator: ", ")
            : (!ambers.isEmpty ? "busy: " + ambers.joined(separator: ", ") : "quiet all the way")
        return HStack(spacing: 10) {
            tile("Jumps", "\(plan.jumps)", jumpsDetail)
            tile("Overall", worstText, worstDetail, color: RouteSystem.lightColor(plan.worst))
            tile("Ganks This Week", "\(plan.ganksWeek)", "\(plan.haulerGanksWeek) of them haulers",
                 color: plan.ganksWeek > 0 ? .orange : .primary)
            tile("Kills Last Hour", "\(plan.killsLastHour)", "ships killed by players on the route")
            tile("Lowest Security", plan.lowestSecurity.map { RouteSystem.securityText($0) } ?? "–",
                 (plan.lowestSecurity ?? 1) < 0.45 ? "leaves high-sec" : "high-sec all the way",
                 color: plan.lowestSecurity.map { RouteSystem.securityColor($0) } ?? .primary)
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).bold().monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(color)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sourceNote(_ plan: HaulRoutePlan) -> String {
        var text = "Lights judge each system against its own traffic and its usual week · only gate kills count when passing through (plus the undock at each end) · kills by players from zKillboard (200+ = its limit) · * = CCP's count"
        if let since = plan.watchingSince {
            text += " · CCP's hourly figures recorded since \(Date(timeIntervalSince1970: since).formatted(date: .abbreviated, time: .shortened))"
        }
        if plan.systems.contains(where: { !$0.zkillOk }) { text += " · zKillboard didn't answer for some systems" }
        if let pods = plan.podKillSystemsAvoided, pods > 0 { text += " · avoiding \(pods) system\(pods == 1 ? "" : "s") with pod kills in the last hour" }
        return text + "."
    }

    private func table(_ plan: HaulRoutePlan) -> some View {
        let numbered = Array(plan.systems.enumerated())
        return Table(numbered.map { NumberedSystem(index: $0.offset, system: $0.element) }, selection: $selection) {
            TableColumn("#") { row in
                Text("\(row.index)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(28)

            TableColumn("System") { row in
                HStack(spacing: 6) {
                    Circle().fill(row.system.lightColor).frame(width: 10, height: 10)
                    Text(row.system.name).fontWeight(row.system.light == "green" ? .regular : .semibold)
                }
                .help(row.system.reasons.joined(separator: "\n"))
            }
            .width(min: 110, ideal: 140)

            TableColumn("Sec") { row in
                Text(row.system.securityText).monospacedDigit()
                    .foregroundStyle(RouteSystem.securityColor(row.system.security))
            }
            .width(36)

            TableColumn("Why") { row in
                Text(row.system.reasons.joined(separator: " · "))
                    .foregroundStyle(row.system.light == "green" ? Color.secondary : row.system.lightColor)
                    .lineLimit(1)
                    .help(row.system.reasons.joined(separator: "\n"))
            }
            .width(min: 140, ideal: 240)

            TableColumn("Jumps / h") { row in
                Text(row.system.jumpsHour.map { $0.short } ?? "–").monospacedDigit()
            }
            .width(min: 55, ideal: 65)

            TableColumn("Kills 1 h") { row in
                let sys = row.system
                Text(RouteSystem.countText(sys.killsHour, capped: sys.killsHourCapped, ccp: sys.fromCCP)).monospacedDigit()
                    .help(sys.killsHelp("last hour", split: sys.splitHour, capped: sys.killsHourCapped, usedCCP: false,
                                        ccp: sys.ccpHour, hours: nil) + "\n\(sys.podsHour) pod(s) lost in the last hour (CCP).")
            }
            .width(min: 50, ideal: 60)

            TableColumn("Kills 24 h") { row in
                let sys = row.system
                Text(RouteSystem.countText(sys.killsDay, capped: sys.killsDayCapped, ccp: sys.fromCCP || sys.killsDayCcp)).monospacedDigit()
                    .help(sys.killsHelp("last 24 hours", split: sys.splitDay, capped: sys.killsDayCapped, usedCCP: sys.killsDayCcp,
                                        ccp: sys.ccpDay, hours: sys.ccpDayHours) + sys.dayHelpExtra)
            }
            .width(min: 55, ideal: 65)

            TableColumn("Kills 7 d") { row in
                let sys = row.system
                Text(RouteSystem.countText(sys.killsWeek, capped: sys.killsWeekCapped, ccp: sys.fromCCP || sys.killsWeekCcp)).monospacedDigit()
                    .help(sys.killsHelp("last 7 days", split: sys.splitWeek, capped: sys.killsWeekCapped, usedCCP: sys.killsWeekCcp,
                                        ccp: sys.ccpWeek, hours: sys.ccpWeekHours))
            }
            .width(min: 50, ideal: 60)

            TableColumn("Ganks 7 d") { row in
                HStack(spacing: 3) {
                    Text(row.system.zkillOk ? "\(row.system.ganksWeek)" : "?").monospacedDigit()
                    if row.system.haulerGanksWeek > 0 {
                        Image(systemName: "shippingbox.fill").font(.caption2)
                        Text("\(row.system.haulerGanksWeek)").monospacedDigit()
                    }
                }
                .foregroundStyle(row.system.haulerGanksWeek > 0 ? Color.red : (row.system.ganksWeek > 0 ? Color.orange : Color.primary))
                .help(row.system.gankHelp)
            }
            .width(min: 60, ideal: 75)

            TableColumn("Region") { row in
                Text(row.system.region ?? "–").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: NumberedSystem.ID.self) { ids in
            if let position = ids.first, plan.systems.indices.contains(position) {
                let system = plan.systems[position]
                let id = system.systemId
                if avoidList.contains(where: { $0.id == id }) {
                    Button("Stop Avoiding \(system.name)") { saveAvoid(avoidList.filter { $0.id != id }) }
                } else {
                    Button("Avoid \(system.name)") { saveAvoid(avoidList + [AvoidEntry(id: id, name: system.name)]) }
                        .disabled(id == fromId || id == toId)
                }
                if viaList.contains(where: { $0.id == id }) {
                    Button("Don't Stop at \(system.name)") { saveVia(viaList.filter { $0.id != id }) }
                } else {
                    Button("Stop at \(system.name) on the Way") { saveVia(viaList + [AvoidEntry(id: id, name: system.name)]) }
                }
                Section("In EVE") {
                    Button("Set Destination in Game") { appState.setDestination(id, name: system.name, clear: true) }
                    Button("Add Waypoint in Game") { appState.setDestination(id, name: system.name, clear: false) }
                    Button("Show Info in Game") { appState.showInGame(id, market: false, name: system.name) }
                }
                Section {
                    Button("Route from Here") { saveFrom(id, system.name) }
                    Button("Route to Here") { saveTo(id, system.name) }
                    Button("Copy Name") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(system.name, forType: .string)
                    }
                    if let url = URL(string: "https://zkillboard.com/system/\(id)/") {
                        Link("Kills on zKillboard", destination: url)
                    }
                    if let url = URL(string: "https://evemaps.dotlan.net/system/\(system.name.replacingOccurrences(of: " ", with: "_"))") {
                        Link("Map on Dotlan", destination: url)
                    }
                }
            }
        }
    }

    /// The table needs an id – the position on the route, since a system can come up twice
    /// (out to a stop and back the same way).
    private struct NumberedSystem: Identifiable {
        let index: Int
        let system: RouteSystem
        var id: Int { index }
    }

    /// The "?" key: what each column means and how the lights are set.
    static let columnKey: [(String, String)] = [
        ("●", "Only kills where you'd be count: on the gates when passing through, plus the station / undock at the start and end – never belts or sites. Red = low/null-sec, a hauler ganked there in the last 24 h, 2+ haulers this week, or a sudden spike (3+ in the last hour, 4× normal). Amber = another gank in the last 24 h, a hauler ganked this week, or 3+ kills in 24 h at double the system's usual or over 5 per 1,000 ships passing. Green = quiet."),
        ("System", "Each system on the way, in order. Hover for why it got its colour. Right-click to avoid it or look it up."),
        ("Sec", "Security status as the game shows it. Below 0.5 there's no CONCORD."),
        ("Why", "What set the light."),
        ("Jumps / h", "Ships jumping through in the last hour (CCP) – how busy it is."),
        ("Kills 1 h / 24 h / 7 d", "Ships killed by players anywhere in the system, each time frame counted on its own. Hover for gates / station / belts and CCP's figure. 200+ = zKillboard's limit reached. * = CCP's count instead."),
        ("Ganks 7 d", "Ships killed by players who CONCORD then destroyed (within 15 minutes). 📦 n = haulers (red). Hover for where and the latest."),
        ("Region", "Which region the system is in."),
    ]

    // MARK: Loading

    private func resolve(_ text: String, isFrom: Bool) async {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard name.count >= 2, name != (isFrom ? fromName : toName) else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        var match = placeCache.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
        if match == nil {
            let found = await appState.backend.searchPlaces(name)
            for place in found.places { placeCache[place.name] = place }
            match = found.places.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        }
        guard let match, !Task.isCancelled else { return }
        if isFrom { fromName = match.name; fromId = match.locationId } else { toName = match.name; toId = match.locationId }
    }

    private func addAvoid(_ text: String, exactOnly: Bool = false) async {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard name.count >= 2 else { return }
        let matches = (try? await appState.backend.searchSystems(name)) ?? []
        let match = matches.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            ?? (exactOnly ? nil : matches.first)
        guard let match, !avoidList.contains(where: { $0.id == match.systemId }) else { return }
        saveAvoid(avoidList + [AvoidEntry(id: match.systemId, name: match.name)])
        avoidAdd = ""
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false; stage = "" }
        let key = loadKey
        func fetch(quick: Bool) async throws -> HaulRoutePlan {
            try await appState.backend.haulRoute(from: fromId, to: toId, via: viaList.map(\.id), mode: mode,
                                                 avoid: avoidList.map(\.id), maxExtra: maxExtra,
                                                 penalty: penalty, avoidPodKills: avoidPodKills,
                                                 preference: autopilot, quick: quick)
        }
        do {
            // 1. The route itself, straight away (only when the route changed, not on a timed refresh).
            if planKey.map({ !$0.sameRoute(as: key) }) ?? true {
                stage = "Planning the route…"
                let first = try await fetch(quick: true)
                guard !Task.isCancelled, key == loadKey else { return }
                plan = first
                planKey = key
                errorMessage = nil
            }
            // 2. Kills and ganks for every system (zKillboard, one system at a time – can take a while).
            stage = "Checking kills and ganks…"
            let full = try await fetch(quick: false)
            guard !Task.isCancelled, key == loadKey else { return }
            plan = full
            planKey = key
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            plan = nil
            planKey = nil
        }
    }

    private func saveFrom(_ id: Int, _ name: String) {
        fromName = name; fromId = id; fromText = name
    }

    private func saveTo(_ id: Int, _ name: String) {
        toName = name; toId = id; toText = name
    }

    private func useMyLocation(quiet: Bool = false) async {
        do {
            let here = try await appState.backend.currentPlace()
            placeCache[here.name] = here
            let sameStart = fromId == here.locationId
            fromName = here.name
            fromId = here.locationId
            fromText = here.name
            // Same start as before: plan again anyway – the first try may have run before the app knew where it is.
            if sameStart && (plan == nil || errorMessage != nil) { refreshCounter += 1 }
        } catch {
            if !quiet { sendStatus = error.localizedDescription }
        }
    }

    private func watchThisRoute() async {
        guard let plan else { return }
        showWatchName = false
        let typed = watchName.trimmingCharacters(in: .whitespaces)
        let name = typed.isEmpty ? "\(plan.fromPlace?.systemName ?? fromName) → \(plan.toPlace?.systemName ?? toName)" : typed
        do {
            try await appState.backend.addWatchRoute(name: name, from: fromId, to: toId,
                                                     via: viaText, avoid: avoidText)
            sendStatus = "Added to the Watch List ✓"
        } catch {
            sendStatus = error.localizedDescription
        }
    }

    private func optimiseStops() async {
        sendStatus = "Finding the best order…"
        do {
            let result = try await appState.backend.optimiseStops(from: fromId, to: toId, via: viaList.map(\.id),
                                                                  preference: autopilot, penalty: penalty,
                                                                  avoid: avoidList.map(\.id))
            let byID = Dictionary(viaList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let ordered = result.via.compactMap { byID[$0] }
            if ordered.count == viaList.count { saveVia(ordered) }
            if let before = result.jumpsBefore, let after = result.jumpsAfter {
                sendStatus = after < before ? "Stops reordered: \(before) → \(after) jumps" : "Already the best order (\(after) jumps)"
            } else {
                sendStatus = nil
            }
        } catch {
            sendStatus = error.localizedDescription
        }
    }

    private func addVia(_ text: String, exactOnly: Bool = false) async {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard name.count >= 2 else { return }
        var match = placeCache.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
        if match == nil {
            let found = await appState.backend.searchPlaces(name)
            for place in found.places { placeCache[place.name] = place }
            match = found.places.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? (exactOnly ? nil : found.places.first)
        }
        guard let match, !viaList.contains(where: { $0.id == match.locationId }) else { return }
        saveVia(viaList + [AvoidEntry(id: match.locationId, name: match.name)])
        viaAdd = ""
    }

    private func send(destinationOnly: Bool, everySystem: Bool = false) {
        guard let plan else { return }
        let path = plan.systems.map(\.systemId)
        let anchors = plan.anchors.map { (index: $0.index, location: $0.locationId) }
        sendStatus = destinationOnly ? "Sending…" : "Working out the fewest waypoints…"
        Task {
            do {
                let sent = try await appState.backend.sendRoute(path: path, anchors: anchors, preference: autopilot,
                                                                 destinationOnly: destinationOnly, everySystem: everySystem,
                                                                 penalty: penalty,
                                                                 gameAvoid: [],   // assume the game avoids nothing – waypoints steer round
                                                                 gameAvoidsPodKills: avoidPodKills)
                sendStatus = destinationOnly ? "Destination set in game ✓"
                    : "Route set in game ✓ – \(sent) waypoint\(sent == 1 ? "" : "s"), starting at \(plan.fromPlace?.name ?? fromName)"
            } catch {
                sendStatus = error.localizedDescription
            }
        }
    }
}
