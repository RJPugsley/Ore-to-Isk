import SwiftUI

// MARK: - Models (/watch/summary)

struct WatchRoute: Decodable, Identifiable {
    let key: String
    let id_: Int?
    let kind: String            // mine · regular · pinned
    let trips: Int?
    let fromLoc: Int
    let toLoc: Int
    let fromName: String
    let toName: String
    let name: String
    let via: String             // "id|name,…"
    let avoid: String           // "id|name,…"
    let ok: Bool?
    let error: String?
    let worst: String
    let worstSystem: String?
    let worstReason: String?
    let jumps: Int
    let ganksWeek: Int
    let haulerGanksWeek: Int
    let haulerGanksDay: Int
    let killsLastHour: Int
    let systems: [RouteSystem]

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, id_ = "id", kind, trips, fromLoc, toLoc, fromName, toName, name, via, avoid, ok, error, worst,
             worstSystem, worstReason, jumps, ganksWeek, haulerGanksWeek, haulerGanksDay, killsLastHour, systems
    }

    var isRegular: Bool { (trips ?? 0) >= 10 }

    var badge: String {
        switch kind {
        case "regular": return "Regular · \(trips ?? 0) trips"
        case "pinned": return "Pinned · \(trips ?? 0) trips"
        default: return isRegular ? "Yours · regular, \(trips ?? 0) trips" : "Yours"
        }
    }
}

struct WatchPlace: Decodable, Identifiable {
    let key: String
    let systemId: Int
    let name: String
    let dockName: String?
    let why: [String]
    /// Docks there + days mined there, last 90 days.
    let visits: Int?
    let row: RouteSystem
    var id: String { key }
}

struct WatchSummary: Decodable {
    let routes: [WatchRoute]
    let places: [WatchPlace]
    let tripsSeen: Int
    let regularTrips: Int
    let regularDays: Int
    let checkedAt: Double
}

// MARK: - View

/// Haul › Watch List: the routes you fly and the places you use, worst first.
struct WatchListView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(AppState.watchNotifyKey) private var notify = true
    /// Places list open? Opens by itself when a place goes amber or red.
    @AppStorage("watch.placesOpen") private var placesOpen = false

    @State private var summary: WatchSummary?
    @State private var errorMessage: String?
    @State private var refreshCounter = 0
    @State private var fresh = false
    @State private var expanded: String?
    @State private var status: String?
    /// The route whose name is being edited, and the text so far.
    @State private var editingKey: String?
    @State private var editName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            if let summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        routesSection(summary)
                        placesSection(summary)
                    }
                    .padding(12)
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load the Watch List", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { refreshCounter += 1 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(summary.map { "\($0.routes.count) routes · \($0.places.count) places" } ?? "")
        .task(id: refreshCounter) { await load() }
        .task {
            // Fresh numbers every 5 minutes while the page is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                refreshCounter += 1
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            if let summary {
                Text("Trips seen: \(summary.tripsSeen) · a route flown \(summary.regularTrips) times in \(summary.regularDays) days (either way) is added by itself")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .help("EVE keeps no travel history an app can read, so trips are counted while this app is open – undock somewhere, dock somewhere else = one trip.")
            }
            Spacer()
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Toggle("Notifications", isOn: $notify)
                .onChange(of: notify) { _, on in if on { appState.requestNotificationPermission() } }
                .help("While the app is running: a Mac notification when a watched route or place turns red, or a hauler is ganked there.")
            PageKeyButton(columns: Self.columnKey)
            Button("Refresh") {
                fresh = true
                refreshCounter += 1
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Routes

    @ViewBuilder
    private func routesSection(_ summary: WatchSummary) -> some View {
        Text("Routes").font(.title3).bold()
        if summary.routes.isEmpty {
            Text("No routes yet. Add one with Watch on the Route page – and routes you fly \(summary.regularTrips) times in \(summary.regularDays) days turn up here by themselves.")
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(summary.routes) { route in routeCard(route) }
            }
            if let key = expanded, let route = summary.routes.first(where: { $0.key == key }) {
                routeDetail(route)
            }
        }
    }

    private func routeCard(_ route: WatchRoute) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(RouteSystem.lightColor(route.worst)).frame(width: 11, height: 11)
                if editingKey == route.key {
                    TextField("Route name", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await rename(route) } }
                    Button("Save") { Task { await rename(route) } }
                        .controlSize(.small)
                    Button("Cancel") { editingKey = nil }
                        .controlSize(.small)
                } else {
                    Text(route.name).font(.headline).lineLimit(1)
                        .onTapGesture(count: 2) { startEditing(route) }
                        .help("Double-click to rename")
                    Button {
                        startEditing(route)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Rename this route")
                }
                Spacer()
                Text(route.badge)
                    .font(.caption2).fontWeight(.medium)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background((route.kind == "regular" ? Color.blue : Color.accentColor).opacity(0.15), in: Capsule())
            }
            Text("\(route.fromName) → \(route.toName)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help("\(route.fromName) → \(route.toName)")
            if let error = route.error {
                Text(error).font(.callout).foregroundStyle(.orange).lineLimit(2)
            } else if let system = route.worstSystem, let reason = route.worstReason {
                Text("\(system): \(reason)").font(.callout)
                    .foregroundStyle(RouteSystem.lightColor(route.worst)).lineLimit(2)
            } else {
                Text(route.worst == "pending" ? "Checking kills and ganks…" : "Quiet all the way")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("\(route.jumps) jumps")
                Text("Ganks 7 d: \(route.ganksWeek)").foregroundStyle(route.ganksWeek > 0 ? Color.orange : Color.secondary)
                if route.haulerGanksWeek > 0 {
                    Label("\(route.haulerGanksWeek)", systemImage: "shippingbox.fill").foregroundStyle(.red)
                        .help("Haulers ganked on this route this week")
                }
                Text("Kills 1 h: \(route.killsLastHour)")
            }
            .font(.caption).monospacedDigit()
            HStack(spacing: 8) {
                Button("Open") { open(route, reverse: false) }
                    .help("Open this route on the Route page")
                Button {
                    open(route, reverse: true)
                } label: {
                    Label("Return Trip", systemImage: "arrow.uturn.backward")
                }
                .help("Open the way back on the Route page")
                Button(expanded == route.key ? "Hide Systems" : "Systems") {
                    expanded = expanded == route.key ? nil : route.key
                }
                Spacer()
                if let id = route.id_ {
                    Button(role: .destructive) {
                        Task { await remove(id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(route.isRegular ? "Stop watching (it comes back by itself while you keep flying it)" : "Stop watching this route")
                } else {
                    Button {
                        Task { await keep(route) }
                    } label: {
                        Image(systemName: "pin")
                    }
                    .buttonStyle(.borderless)
                    .help("Keep this route even if you stop flying it")
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(expanded == route.key ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .contextMenu {
            Button("Open on the Route Page") { open(route, reverse: false) }
            Button("Return Trip") { open(route, reverse: true) }
            Button("Rename…") { startEditing(route) }
            Button(expanded == route.key ? "Hide Systems" : "Show Systems") {
                expanded = expanded == route.key ? nil : route.key
            }
            Divider()
            if let id = route.id_ {
                Button("Stop Watching") { Task { await remove(id) } }
            } else {
                Button("Pin This Route") { Task { await keep(route) } }
            }
            Divider()
            PlaceMenu(locationID: route.fromLoc, name: route.fromName)
            PlaceMenu(locationID: route.toLoc, name: route.toName)
        }
    }

    private func routeDetail(_ route: WatchRoute) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(route.name + " – system by system").font(.headline).padding(.top, 4)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("#"); Text("System"); Text("Sec"); Text("Why"); Text("Kills 1 h"); Text("Kills 24 h"); Text("Ganks 7 d")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(route.systems.enumerated()), id: \.offset) { index, system in
                    GridRow {
                        Text("\(index)").foregroundStyle(.secondary)
                        HStack(spacing: 5) {
                            Circle().fill(system.lightColor).frame(width: 9, height: 9)
                            Text(system.name)
                        }
                        Text(system.securityText).foregroundStyle(RouteSystem.securityColor(system.security))
                        Text(system.reasons.joined(separator: " · ")).lineLimit(1)
                            .foregroundStyle(system.light == "green" ? Color.secondary : system.lightColor)
                        Text("\(system.killsHour)")
                        Text(system.killsDay.map { "\($0)" } ?? "–")
                        Text("\(system.ganksWeek)").foregroundStyle(system.ganksWeek > 0 ? Color.orange : Color.primary)
                    }
                    .font(.callout).monospacedDigit()
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Places – a folded list, most used first; opens by itself when one goes amber or red

    private func trouble(_ summary: WatchSummary) -> [WatchPlace] {
        summary.places.filter { $0.row.light == "red" || $0.row.light == "amber" }
    }

    @ViewBuilder
    private func placesSection(_ summary: WatchSummary) -> some View {
        let bad = trouble(summary)
        if let worst = bad.first(where: { $0.row.light == "red" }) ?? bad.first {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(worst.row.lightColor)
                Text("\(worst.name): \(worst.row.reasons.first ?? "")").foregroundStyle(worst.row.lightColor)
                if bad.count > 1 { Text("+\(bad.count - 1) more").foregroundStyle(.secondary) }
            }
            .font(.callout)
        }
        DisclosureGroup(isExpanded: $placesOpen) {
            if summary.places.isEmpty {
                Text("Your home, where you mine and dock, and where your hangars, jobs and orders are show up here.")
                    .foregroundStyle(.secondary).padding(.top, 4)
            } else {
                placesTable(summary.places).padding(.top, 6)
            }
        } label: {
            Text(bad.isEmpty
                 ? "Places (\(summary.places.count)) – all quiet"
                 : "Places (\(summary.places.count)) – \(bad.count) need\(bad.count == 1 ? "s" : "") watching")
                .font(.headline)
                .foregroundStyle(bad.isEmpty ? Color.primary : Color.orange)
        }
    }

    private func placesTable(_ places: [WatchPlace]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                Text("System"); Text("Sec"); Text("Where"); Text("Why watched"); Text("Now")
                Text("Kills 1 h"); Text("24 h"); Text("Ganks 7 d"); Text("Visits")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(places) { place in
                let row = place.row
                GridRow {
                    HStack(spacing: 5) {
                        Circle().fill(row.lightColor).frame(width: 9, height: 9)
                        Text(place.name)
                    }
                    Text(row.securityText).foregroundStyle(RouteSystem.securityColor(row.security))
                    Text(place.dockName ?? "–").lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                        .foregroundStyle(.secondary).help(place.dockName ?? "")
                    Text(place.why.joined(separator: ", ")).lineLimit(1).foregroundStyle(.secondary)
                    Text(row.reasons.joined(separator: " · ")).lineLimit(1)
                        .foregroundStyle(row.light == "green" ? Color.secondary : row.lightColor)
                        .help(row.reasons.joined(separator: "\n"))
                    Text("\(row.killsHour)")
                    Text(row.killsDay.map { "\($0)" } ?? "–")
                    HStack(spacing: 3) {
                        Text("\(row.ganksWeek)")
                        if row.haulerGanksWeek > 0 {
                            Image(systemName: "shippingbox.fill").font(.caption2)
                            Text("\(row.haulerGanksWeek)")
                        }
                    }
                    .foregroundStyle(row.haulerGanksWeek > 0 ? Color.red : (row.ganksWeek > 0 ? Color.orange : Color.primary))
                    Text("\(place.visits ?? 0)").foregroundStyle(.secondary)
                        .help("Times you've docked there plus days you've mined there, last 90 days")
                }
                .font(.callout).monospacedDigit()
                .contextMenu { PlaceMenu(locationID: place.systemId, name: place.name) }
            }
        }
    }

    /// The "?" key.
    static let columnKey: [(String, String)] = [
        ("Routes", "Yours (added with Watch on the Route page) and regular ones – flown 10 times in 90 days, either way round, counted while the app is open. Sorted worst first."),
        ("● light", "The worst system on the route, judged like the Route page: gate kills on the way, your undock at each end, ganks, spikes."),
        ("Open / Return Trip", "Opens the route – or the way back – on the Route page, ready to send to the game."),
        ("📌 / 🗑", "Pin a regular route to keep it even if you stop flying it; the bin stops watching one."),
        ("Places", "Home, where you mine and dock, and where your hangars, jobs and orders are – folded away, most used first, and opened by itself when one goes amber or red."),
        ("Notifications", "While the app runs, it checks every 15 minutes and tells you when a watched route or place turns red or a hauler is ganked there."),
    ]

    // MARK: Actions

    private func load() async {
        let wantFresh = fresh
        fresh = false
        do {
            if summary == nil {
                let first = try await appState.backend.watchSummary(quick: true)
                guard !Task.isCancelled else { return }
                summary = first
                errorMessage = nil
            }
            let full = try await appState.backend.watchSummary(quick: false, fresh: wantFresh)
            guard !Task.isCancelled else { return }
            summary = full
            errorMessage = nil
            if !trouble(full).isEmpty { placesOpen = true }   // something needs watching – show it
        } catch {
            guard !Task.isCancelled else { return }
            if summary == nil { errorMessage = error.localizedDescription }
        }
    }

    /// Put the route on the Route page and go there.
    private func open(_ route: WatchRoute, reverse: Bool) {
        let d = UserDefaults.standard
        let viaParts = route.via.split(separator: ",").map(String.init)
        let (fromID, fromName, toID, toName) = reverse
            ? (route.toLoc, route.toName, route.fromLoc, route.fromName)
            : (route.fromLoc, route.fromName, route.toLoc, route.toName)
        d.set(fromID, forKey: "route.fromId")
        d.set(fromName, forKey: "route.fromName")
        d.set(toID, forKey: "route.toId")
        d.set(toName, forKey: "route.toName")
        d.set((reverse ? viaParts.reversed() : viaParts).joined(separator: ","), forKey: "route.via")
        if !route.avoid.isEmpty { d.set(route.avoid, forKey: "route.avoid") }
        d.set(true, forKey: "route.skipAutoLocation")
        appState.goToPage = .haulRoute
    }

    private func startEditing(_ route: WatchRoute) {
        editName = route.name
        editingKey = route.key
    }

    /// Your own routes are renamed in place; a regular route is kept (pinned) under the new name.
    private func rename(_ route: WatchRoute) async {
        let name = editName.trimmingCharacters(in: .whitespaces)
        editingKey = nil
        guard !name.isEmpty, name != route.name else { return }
        do {
            if let id = route.id_ {
                try await appState.backend.renameWatchRoute(id: id, name: name)
            } else {
                try await appState.backend.addWatchRoute(name: name, from: route.fromLoc, to: route.toLoc,
                                                         via: route.via, avoid: route.avoid, kind: "pinned")
            }
            fresh = true
            refreshCounter += 1
        } catch {
            status = error.localizedDescription
        }
    }

    private func remove(_ id: Int) async {
        let name = summary?.routes.first { $0.id_ == id }?.name ?? "this route"
        guard Confirm.delete("watch.remove", title: "Stop watching \(name)?",
                             message: "It disappears from the Watch List (a regular route comes back by itself while you keep flying it).",
                             button: "Stop Watching") else { return }
        do {
            try await appState.backend.deleteWatchRoute(id: id)
            fresh = true
            refreshCounter += 1
        } catch {
            status = error.localizedDescription
        }
    }

    private func keep(_ route: WatchRoute) async {
        do {
            try await appState.backend.addWatchRoute(name: route.name, from: route.fromLoc, to: route.toLoc,
                                                     via: route.via, avoid: route.avoid, kind: "pinned")
            status = "Pinned ✓"
            fresh = true
            refreshCounter += 1
        } catch {
            status = error.localizedDescription
        }
    }
}
