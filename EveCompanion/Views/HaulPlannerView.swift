import SwiftUI

// MARK: - Models (/haul/...)

struct HaulShip: Decodable, Identifiable, Hashable {
    let itemId: Int
    let typeId: Int
    let typeName: String
    let name: String?
    let locationId: Int
    let location: String
    let baseCapacity: Double
    let cargo: Double
    let skillName: String?
    let skillLevel: Int
    let bonusPerLevel: Double
    let modules: [String]
    let moduleMultiplier: Double

    var id: Int { itemId }

    var label: String {
        let custom = (name ?? "").isEmpty ? "" : " '\(name!)'"
        return "\(typeName)\(custom) · \(cargo.short) m³ · \(location)"
    }

    var help: String {
        var text = "Cargo hold \(baseCapacity.short) m³"
        if let skillName, bonusPerLevel > 0 {
            text += " + \(Int(bonusPerLevel))% per level of \(skillName) (you have \(skillLevel.roman))"
        }
        if !modules.isEmpty {
            text += "\nFitted: " + modules.joined(separator: ", ")
                + " (×\(String(format: "%.3f", moduleMultiplier)))"
        }
        text += "\n= \(cargo.short) m³. Type your in-game figure in the box if it differs."
        return text
    }
}

struct HaulTrip: Decodable, Identifiable {
    let trip: Int
    let m3: Double
    let value: Double
    let items: Int
    let risky: Bool
    var id: Int { trip }
}

struct HaulSystem: Decodable, Identifiable {
    let systemId: Int
    let name: String
    let security: Double?
    var id: Int { systemId }
}

struct HaulRoute: Decodable {
    let jumps: Int
    let lowestSecurity: Double?
    let systems: [HaulSystem]

    var help: String {
        systems.map { s in
            s.name + (s.security.map { String(format: " (%.1f)", $0) } ?? "")
        }.joined(separator: " → ")
    }
}

struct HaulShipCount: Decodable {
    let name: String
    let count: Int
}

struct HaulItem: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let group: String?
    let quantity: Int
    let unitM3: Double
    let totalM3: Double
    let marketable: Bool
    let sellEach: Double?
    let value: Double?
    let instantValue: Double?
    let iskPerM3: Double?
    let check: PriceCheck?
    let spread: String?
    let soldPerDay: Double?
    let included: Bool
    let assembled: Bool?
    let trips: [Int]
    let tooBig: Bool

    var id: Int { typeId }

    // Sort keys – nothing to compare → bottom.
    var valueSort: Double { value ?? -1 }
    var perM3Sort: Double { iskPerM3 ?? -1 }
    var sellSort: Double { sellEach ?? -1 }
    var soldSort: Double { soldPerDay ?? -1 }
    var tripSort: Int { trips.first ?? Int.max }
    var includedSort: Int { included ? 1 : 0 }

    var tripText: String {
        if !included { return "Left behind" }
        if tooBig { return "Too big" }
        guard let first = trips.first, let last = trips.last else { return "–" }
        if first == last { return "\(first)" }
        let contiguous = trips == Array(first...last)
        return contiguous ? "\(first)–\(last)" : trips.map(String.init).joined(separator: ", ")
    }

    var worthHelp: String {
        guard let value else {
            return marketable ? "No sell orders or sales history at the hub – can't put a value on it." : "Not sold on the market."
        }
        var text = "\(value.iskShort) after broker fee and sales tax, listing at \((sellEach ?? 0).iskShort) each."
        if let instantValue { text += "\nSelling straight to buy orders instead: \(instantValue.iskShort)." }
        return text
    }

    func badges(hub: String, lookback: Int) -> [PriceBadge] {
        PriceBadge.badges(check, place: hub, lookback: lookback, what: "\(quantity.short) \(name)", spread: spread)
    }
}

struct HaulPlan: Decodable {
    let startLocation: Int
    let startName: String
    let hub: String
    let hubStation: String
    let cargo: Double
    let brokerFee: Double
    let salesTax: Double
    let lookbackDays: Int
    let warnValue: Double
    let items: [HaulItem]
    let trips: [HaulTrip]
    let totalM3: Double
    let totalValue: Double
    let tooBig: Int
    let priceGaps: Int
    let assembledShips: [HaulShipCount]
    let route: HaulRoute?
}

// MARK: - View

/// Haul › Haul Planner: what's at a station, what it's worth where you sell, and how many trips it takes.
struct HaulPlannerView: View {
    @Environment(AppState.self) private var appState

    @AppStorage("haul.start") private var start = 0
    @AppStorage("haul.hub") private var hub = BuildSettingsKey.defaultHub
    /// 0 = cargo typed in; otherwise the ship's item id.
    @AppStorage("haul.shipId") private var shipId = 0
    @AppStorage("haul.cargo") private var cargo = 0.0
    @AppStorage("haul.warnMillions") private var warnMillions = 500.0
    @AppStorage("haul.excluded") private var excludedText = ""
    @AppStorage(PriceCheckKey.lookbackDays) private var lookbackDays = 30

    @State private var locations: [StockLocation] = []
    @State private var ships: [HaulShip] = []
    @State private var plan: HaulPlan?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var refreshCounter = 0
    @State private var sortOrder = [KeyPathComparator(\HaulItem.perM3Sort, order: .reverse)]
    @State private var selection: HaulItem.ID?

    private var excluded: Set<Int> {
        Set(excludedText.split(separator: ",").compactMap { Int($0) })
    }

    private struct LoadKey: Hashable {
        var start: Int
        var hub: String
        var cargo: Double
        var warn: Double
        var excluded: String
        var refresh: Int
    }

    private var loadKey: LoadKey {
        LoadKey(start: start, hub: hub, cargo: cargo, warn: warnMillions, excluded: excludedText, refresh: refreshCounter)
    }

    private var rows: [HaulItem] { (plan?.items ?? []).sorted(using: sortOrder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            if let plan {
                content(plan)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Plan the Haul", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { refreshCounter += 1 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if start == 0 && !locations.isEmpty {
                ContentUnavailableView("Pick Where You're Hauling From", systemImage: "shippingbox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Reading your hangar and \(hub) prices…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(plan.map { "\($0.startName) → \($0.hub)" } ?? "")
        .task {
            await loadChoices()
        }
        .task(id: loadKey) { await load() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("From", selection: $start) {
                    if start == 0 { Text("Choose…").tag(0) }
                    ForEach(locations) { place in
                        Text("\(place.name) (\(place.items))").tag(place.locationId)
                    }
                    if start != 0 && !locations.contains(where: { $0.locationId == start }) {
                        Text(plan?.startName ?? "Saved location").tag(start)
                    }
                }
                .frame(maxWidth: 420)
                .help("Stations and structures where you have things – the busiest first")

                Image(systemName: "arrow.right").foregroundStyle(.secondary)

                Picker("Sell at", selection: $hub) {
                    ForEach(TradeHub.allCases) { item in Text(item.rawValue).tag(item.rawValue) }
                }
                .frame(width: 160)

                Spacer()
                PriceCheckMenu()
                PageKeyButton(columns: Self.columnKey)
                Button("Refresh") {
                    refreshCounter += 1
                    Task { await loadChoices() }
                }
            }

            HStack(spacing: 12) {
                Picker("Ship", selection: $shipId) {
                    Text("Type cargo size").tag(0)
                    if !ships.isEmpty { Divider() }
                    ForEach(ships) { ship in Text(ship.label).tag(ship.itemId) }
                    if shipId != 0 && !ships.contains(where: { $0.itemId == shipId }) {
                        Text("Saved ship").tag(shipId)
                    }
                }
                .frame(maxWidth: 420)
                .help(ships.first(where: { $0.itemId == shipId })?.help
                      ?? "Your ships with a cargo hold of 1,000 m³ or more – hold size with skills and fitted expanders / rigs.")
                .onChange(of: shipId) { _, id in
                    if let ship = ships.first(where: { $0.itemId == id }) { cargo = ship.cargo.rounded(.down) }
                }

                HStack(spacing: 4) {
                    Text("Cargo")
                    TextField("m³", value: $cargo, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text("m³").foregroundStyle(.secondary)
                }
                .help("Room in the hold for one trip. Picking a ship fills this in; type over it if your in-game figure differs.")

                HStack(spacing: 4) {
                    Text("Warn when a trip is worth over")
                    TextField("m", value: $warnMillions, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                    Text("m").foregroundStyle(.secondary)
                }
                .help("Trips carrying more than this (in millions) are marked red – worth splitting, or flying a tougher hauler.")

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Content

    private func content(_ plan: HaulPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            tiles(plan)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            if !plan.trips.isEmpty { tripStrip(plan) }
            notes(plan)
            table(plan)
        }
    }

    private func tiles(_ plan: HaulPlan) -> some View {
        let biggest = plan.trips.max { $0.value < $1.value }
        let included = plan.items.filter(\.included).count
        let fees = (plan.brokerFee + plan.salesTax) * 100
        return HStack(spacing: 10) {
            tile("To Haul", "\(plan.totalM3.short) m³",
                 "\(included) of \(plan.items.count) item types")
            tile("Worth at \(plan.hub)", plan.totalValue.short,
                 String(format: "after %.2f%% broker fee + sales tax", fees))
            tile("Trips", plan.cargo > 0 ? "\(plan.trips.count)" : "–",
                 plan.cargo > 0 ? "of \(plan.cargo.short) m³" : "Pick a ship or type a cargo size")
            tile("Route", plan.route.map { "\($0.jumps) jumps" } ?? "–",
                 plan.route.map { r in
                     "safest · lowest security " + (r.lowestSecurity.map { String(format: "%.1f", $0) } ?? "–")
                 } ?? "Route unknown",
                 color: (plan.route?.lowestSecurity ?? 1) < 0.45 ? .red : .primary)
                .help(plan.route?.help ?? "")
            tile("Richest Trip", biggest.map { $0.value.short } ?? "–",
                 "warn above \((plan.warnValue).short)",
                 color: (biggest?.risky ?? false) ? .red : .primary)
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

    private func tripStrip(_ plan: HaulPlan) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(plan.trips) { trip in
                    HStack(spacing: 4) {
                        if trip.risky { Image(systemName: "exclamationmark.triangle.fill") }
                        Text("Trip \(trip.trip)").fontWeight(.semibold)
                        Text("\(trip.m3.short) m³ · \(trip.value.short)")
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(trip.risky ? Color.red : Color.primary)
                    .background((trip.risky ? Color.red : Color.secondary).opacity(0.12), in: Capsule())
                    .help("\(trip.items) stack(s) · \(Int((trip.m3 / max(plan.cargo, 1) * 100).rounded()))% full"
                          + (trip.risky ? "\nWorth more than \(plan.warnValue.short) – a tempting target for gankers." : ""))
                }
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func notes(_ plan: HaulPlan) -> some View {
        let lines: [String] = {
            var list: [String] = []
            if plan.tooBig > 0 { list.append("\(plan.tooBig) item(s) are too big for the hold.") }
            if plan.priceGaps > 0 { list.append("\(plan.priceGaps) price(s) couldn't be fetched – Refresh to try again.") }
            if !plan.assembledShips.isEmpty {
                let names = plan.assembledShips.map { $0.count > 1 ? "\($0.count)× \($0.name)" : $0.name }
                list.append("Assembled ships fly themselves, so they're left out: " + names.joined(separator: ", ") + ".")
            }
            return list
        }()
        if !lines.isEmpty {
            Text(lines.joined(separator: " "))
                .font(.callout).foregroundStyle(.orange)
                .padding(.horizontal, 12)
        }
    }

    private func table(_ plan: HaulPlan) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Haul", value: \.includedSort) { item in
                Toggle("", isOn: Binding(get: { item.included }, set: { setIncluded(item.typeId, $0) }))
                    .labelsHidden()
                    .help("Untick to leave this behind")
            }
            .width(40)

            TableColumn("Item", value: \.name) { item in
                HStack(spacing: 6) {
                    AsyncImage(url: PublicESIClient.typeIconURL(typeID: item.typeId, size: 32)) { image in
                        image.resizable()
                    } placeholder: { Color.clear }
                    .frame(width: 18, height: 18)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(item.included ? Color.primary : Color.secondary)
                }
                .help(item.name + (item.group.map { "\n\($0)" } ?? ""))
            }
            .width(min: 140, ideal: 220)

            TableColumn("Qty", value: \.quantity) { item in
                Text(item.quantity.short).monospacedDigit()
            }
            .width(min: 45, ideal: 60)

            TableColumn("m³", value: \.totalM3) { item in
                Text(item.totalM3.short).monospacedDigit()
                    .help("\(item.unitM3.short) m³ each" + ((item.assembled ?? false) ? " (assembled – repackage to save space)" : ""))
            }
            .width(min: 50, ideal: 70)

            TableColumn("Sell Each", value: \.sellSort) { item in
                HStack(spacing: 4) {
                    Text(item.sellEach?.short ?? "–").monospacedDigit()
                    PriceBadgesView(badges: item.badges(hub: plan.hub, lookback: plan.lookbackDays).priceOnly)
                }
            }
            .width(min: 70, ideal: 110)

            TableColumn("Worth", value: \.valueSort) { item in
                Text(item.value?.short ?? (item.marketable ? "No price" : "Not on market")).monospacedDigit()
                    .foregroundStyle(item.value == nil ? Color.secondary : Color.primary)
                    .help(item.worthHelp)
            }
            .width(min: 60, ideal: 80)

            TableColumn("ISK / m³", value: \.perM3Sort) { item in
                Text(item.iskPerM3?.short ?? "–").monospacedDigit().fontWeight(.semibold)
                    .help("What each m³ of hold space earns for this item – trips are filled with the best first.")
            }
            .width(min: 60, ideal: 80)

            TableColumn("Sold / Day", value: \.soldSort) { item in
                HStack(spacing: 4) {
                    Text(item.soldPerDay.map { $0 >= 10 ? $0.short : String(format: "%.1f", $0) } ?? "–").monospacedDigit()
                    PriceBadgesView(badges: item.badges(hub: plan.hub, lookback: plan.lookbackDays).marketOnly)
                }
                .help(item.check?.daysToSell.map { "About \(Int($0.rounded(.up))) day(s) to sell this many at the usual pace." } ?? "")
            }
            .width(min: 70, ideal: 110)

            TableColumn("Trip", value: \.tripSort) { item in
                Text(item.tripText).monospacedDigit()
                    .foregroundStyle(item.tooBig ? Color.orange : (item.included ? Color.primary : Color.secondary))
            }
            .width(min: 50, ideal: 70)
        }
        .contextMenu(forSelectionType: HaulItem.ID.self) { ids in
            if let id = ids.first, let item = rows.first(where: { $0.id == id }) {
                Button(item.included ? "Leave Behind" : "Take It") { setIncluded(item.typeId, !item.included) }
                ItemMenu(typeID: item.typeId, name: item.name, quantity: item.quantity)
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "shippingbox",
                                       description: Text("You have nothing at \(plan.startName) to haul."))
            }
        }
    }

    /// The "?" key: what each column means.
    static let columnKey: [(String, String)] = [
        ("Haul", "Untick to leave an item behind – it drops out of the trips and totals (remembered)."),
        ("Item", "Everything at the start: hangar, containers and ship cargo. Fitted modules and assembled ships are left out."),
        ("Qty", "How many you have there."),
        ("m³", "Space it takes (packaged size unless it's assembled)."),
        ("Sell Each", "Price you'd list at in the hub, averaged over the orders you'd compete with and checked against the fair price."),
        ("Worth", "Qty × sell each, after broker fee and sales tax. Hover for the instant-sell figure."),
        ("ISK / m³", "Worth per m³ of hold – the higher, the more each trip earns. Trips are packed best first."),
        ("Sold / Day", "Average daily sales in the hub's region – how fast it'll go."),
        ("Trip", "Which trip(s) it goes on. Big stacks are split across trips."),
    ]

    // MARK: Loading

    private func setIncluded(_ typeID: Int, _ on: Bool) {
        var set = excluded
        if on { set.remove(typeID) } else { set.insert(typeID) }
        excludedText = set.sorted().map(String.init).joined(separator: ",")
    }

    private func loadChoices() async {
        locations = (try? await appState.backend.stockLocations()) ?? []
        ships = (try? await appState.backend.haulShips()) ?? []
        if start == 0 {
            start = locations.first?.locationId ?? 0     // the busiest place comes first
        }
        // Keep the hold size in step with the ship (refits, skills).
        if let ship = ships.first(where: { $0.itemId == shipId }) {
            cargo = ship.cargo.rounded(.down)
        } else if shipId == 0 && cargo == 0, let biggest = ships.first {
            shipId = biggest.itemId
            cargo = biggest.cargo.rounded(.down)
        }
    }

    private func load() async {
        guard start != 0 else { return }
        isLoading = true
        defer { isLoading = false }
        let key = loadKey
        do {
            let result = try await appState.backend.haulPlan(start: start, hub: hub, cargo: cargo,
                                                             excluded: excluded, warnValue: warnMillions * 1_000_000)
            guard !Task.isCancelled, key == loadKey else { return }
            plan = result
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            plan = nil
        }
    }
}
