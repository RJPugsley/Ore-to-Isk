import SwiftUI

/// Pick what you want to build → the mix of ore with the fewest m³ that covers the minerals,
/// after what you already have (stock + ore waiting at the refinery), using your real yields.
struct BuildPlannerView: View {
    @State private var highlight = RowHighlights()
    @Environment(AppState.self) private var appState

    @AppStorage("buildPlanner.items") private var itemsText = ""
    /// Areas you mine in, e.g. "High" or "High,Low".
    @AppStorage("buildPlanner.spaces") private var spaces = "High"

    private struct Band: Identifiable {
        let key: String
        let label: String
        let help: String
        var id: String { key }
    }

    private static let bands: [Band] = [
        Band(key: "High", label: "High-sec (0.5 – 1.0)", help: "Ore found in high-security space"),
        Band(key: "Low", label: "Low-sec (0.1 – 0.4)", help: "Ore found in low-security space"),
        Band(key: "Null", label: "Null-sec (0.0 and below)", help: "Ore found in null-security space"),
        Band(key: "Pochven", label: "Pochven", help: "Spodumain, Bezdnacine, Rakovene, Talassonite"),
    ]

    private var selectedBands: Set<String> { Set(spaces.split(separator: ",").map { String($0) }) }

    private func bandBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { selectedBands.contains(key) },
            set: { on in
                var bands = selectedBands
                if on { bands.insert(key) } else { bands.remove(key) }
                if bands.isEmpty { bands = ["High"] } // always at least one
                spaces = Self.bands.map { $0.key }.filter { bands.contains($0) }.joined(separator: ",")
            })
    }
    @AppStorage("buildPlanner.subtractStock") private var subtractStock = true
    /// Build components yourself: break them down into their own materials (and ore).
    @AppStorage("buildPlanner.breakDown") private var breakDown = true
    /// Count stock at other stations too (listed so you can fetch it).
    @AppStorage("buildPlanner.useElsewhere") private var useElsewhere = true

    @AppStorage(BuildSettingsKey.structure) private var structure = StructureKind.npc.rawValue
    @AppStorage(BuildSettingsKey.rigME) private var rigME = 0.0
    @AppStorage(BuildSettingsKey.materialHub) private var materialHub = BuildSettingsKey.defaultHub
    @AppStorage(BuildSettingsKey.systemId) private var systemId = BuildSettingsKey.defaultSystemId
    @AppStorage(BuildSettingsKey.facilityTax) private var facilityTax = 0.25
    /// Same sell hub as Build vs Sell, so both pages agree on the profit.
    @AppStorage("buildVsSell.sellHub") private var sellHub = "best"
    @AppStorage(BuildSettingsKey.stockLocationId) private var stockLocationId = 0
    @AppStorage(BuildSettingsKey.stockLocationName) private var stockLocationName = ""
    @AppStorage(BuildSettingsKey.refineryId) private var refineryId = 0
    @AppStorage(BuildSettingsKey.useOre) private var useOre = true
    @AppStorage(BuildSettingsKey.oreYield) private var oreYield = BuildSettingsKey.defaultOreYield
    @AppStorage(BuildSettingsKey.oreYieldSkill) private var oreYieldSkill = BuildSettingsKey.defaultOreYieldSkill
    @AppStorage(BuildSettingsKey.iceYield) private var iceYield = BuildSettingsKey.defaultIceYield
    @AppStorage(BuildSettingsKey.refineryTax) private var refineryTax = BuildSettingsKey.defaultRefineryTax

    @State private var myProducts: [ProductOption] = []
    @State private var searchText = ""
    @State private var searchResults: [ProductOption] = []
    /// Ticked: only your own blueprints (and the search looks only through those).
    @AppStorage("buildPlanner.ownedOnly") private var ownedOnly = false
    @AppStorage("buildPlanner.category") private var browseCategory = "Ship"
    @AppStorage("buildPlanner.group") private var browseGroup = "Frigate"
    @State private var categories: [BlueprintCategory] = []
    @State private var groupProducts: [ProductOption] = []

    private var ownedIDs: Set<Int> { Set(myProducts.map(\.blueprintTypeId)) }

    private var browseGroups: [BlueprintGroup] {
        categories.first { $0.name == browseCategory }?.groups ?? []
    }

    /// What the Add list shows.
    private var addList: [ProductOption] {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if ownedOnly {
            return text.isEmpty ? myProducts : myProducts.filter { $0.productName.localizedCaseInsensitiveContains(text) }
        }
        return text.count >= 2 ? searchResults : groupProducts
    }
    @State private var names: [Int: String] = [:]
    @State private var plan: BuildPlan?
    @State private var errorMessage: String?
    @State private var isPlanning = false
    @State private var oreSort = [KeyPathComparator(\PlannedOre.m3, order: .reverse)]
    @State private var buildSort = [KeyPathComparator(\BuildFirstItem.toBuild, order: .reverse)]
    @State private var buySort = [KeyPathComparator(\OtherMaterial.valueSort, order: .reverse)]
    @State private var showBuildFirst = true
    @State private var openSources: Set<String> = ["reaction", "planetary", "moon", "salvage", "buy"]

    private struct Line: Identifiable, Hashable {
        let blueprintTypeID: Int
        var runs: Int
        var id: Int { blueprintTypeID }
    }

    private var lines: [Line] {
        itemsText.split(separator: ",").compactMap { part in
            let bits = part.split(separator: ":")
            guard let bp = bits.first.flatMap({ Int($0) }) else { return nil }
            return Line(blueprintTypeID: bp, runs: bits.count > 1 ? max(1, Int(bits[1]) ?? 1) : 1)
        }
    }

    /// Runs for one line – shared by the text box and the arrows.
    private func runsBinding(_ line: Line) -> Binding<Int> {
        Binding(
            get: { line.runs },
            set: { newValue in
                var all = lines
                if let index = all.firstIndex(where: { $0.id == line.id }) {
                    all[index].runs = min(max(1, newValue), 100_000)
                }
                save(all)
            })
    }

    private func lineName(_ line: Line) -> String {
        names[line.blueprintTypeID] ?? plan?.items.first { $0.blueprintTypeId == line.blueprintTypeID }?.productName ?? "Blueprint \(line.blueprintTypeID)"
    }

    /// Asks first (unless you ticked "Don't ask again").
    private func remove(_ line: Line) {
        guard Confirm.delete("buildPlanner.remove", title: "Remove \(lineName(line)) from the plan?",
                             message: "You can add it back from the Add list or any right-click menu.", button: "Remove") else { return }
        save(lines.filter { $0.id != line.id })
    }

    private func save(_ lines: [Line]) {
        itemsText = lines.map { "\($0.blueprintTypeID):\($0.runs)" }.joined(separator: ",")
    }

    private struct PlanKey: Hashable {
        var items: String, spaces: String, subtract: Bool, breakDown: Bool, structure: String, rigME: Double
        var stock: Int, refinery: Int, useOre: Bool, oreYield: Double, oreSkill: String, iceYield: Double, tax: Double
        var system: Int, facilityTax: Double, sellHub: String, hub: String, elsewhere: Bool
    }

    private var planKey: PlanKey {
        PlanKey(items: itemsText, spaces: spaces, subtract: subtractStock, breakDown: breakDown, structure: structure, rigME: rigME,
                stock: stockLocationId, refinery: refineryId, useOre: useOre, oreYield: oreYield,
                oreSkill: oreYieldSkill, iceYield: iceYield, tax: refineryTax,
                system: systemId, facilityTax: facilityTax, sellHub: sellHub, hub: materialHub, elsewhere: useElsewhere)
    }

    var body: some View {
        HSplitView {
            buildList
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            results
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            myProducts = (try? await appState.backend.myProducts()) ?? []
            for p in myProducts { names[p.blueprintTypeId] = p.productName }
        }
        .task {
            if categories.isEmpty { categories = (try? await appState.backend.blueprintCategories()) ?? [] }
        }
        .task(id: "\(browseCategory)|\(browseGroup)") {
            // Changing Category clears Group for a moment, so several look-ups can be in flight.
            // Only the latest may fill the list – an older, slower answer is thrown away.
            let category = browseCategory
            let group = browseGroup
            let found = (try? await appState.backend.productsInGroup(category: category, group: group)) ?? []
            guard !Task.isCancelled, category == browseCategory, group == browseGroup else { return }
            groupProducts = found
        }
        .task(id: "\(searchText)|\(ownedOnly)") {
            let text = searchText.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2, !ownedOnly else { searchResults = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = (try? await appState.backend.searchProducts(text)) ?? []
            guard !Task.isCancelled else { return }
            searchResults = found
        }
        .task(id: planKey) { await makePlan() }
    }

    // MARK: Left: what to build

    private var buildList: some View {
        List {
            Section("To Build") {
                if lines.isEmpty {
                    Text("Add something below – e.g. a Venture – and set how many runs.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(names[line.blueprintTypeID] ?? plan?.items.first { $0.blueprintTypeId == line.blueprintTypeID }?.productName ?? "Blueprint \(line.blueprintTypeID)")
                            .lineLimit(1)
                        Spacer()
                        TextField("Runs", value: runsBinding(line), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 64)
                            .help("Runs – type a number or use the arrows")
                        Stepper("Runs", value: runsBinding(line), in: 1...100_000)
                            .labelsHidden()
                        Text("runs").foregroundStyle(.secondary)
                        Button {
                            remove(line)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                    itemMoneyLine(line.blueprintTypeID)
                    }
                    .contextMenu {
                        let name = lineName(line)
                        if let product = appState.product(ofBlueprint: line.blueprintTypeID) {
                            ItemMenu(typeID: product, name: name)
                        }
                        Section {
                            Button("Remove from Plan") { remove(line) }
                            Button("Clear the Whole Plan") {
                                if Confirm.delete("buildPlanner.clear", title: "Clear the whole plan?",
                                                  message: "Every item is taken off the Build Planner.", button: "Clear") {
                                    save([])
                                }
                            }
                        }
                    }
                }
            }

            Section("Options") {
                Text("Where you mine – ordinary belt ore only (plain, II- and III-Grade)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Self.bands) { band in
                    Toggle(band.label, isOn: bandBinding(band.key))
                        .help(band.help + " (from Config/ore_locations.json)")
                }
                Toggle("Build components myself", isOn: $breakDown)
                    .help("Components with a blueprint (e.g. Structure Construction Parts) are broken down into their own materials, all the way down – so the ore plan covers them too. Untick to treat them as things to buy.")
                Toggle("Subtract what I already have", isOn: $subtractStock)
                    .help(stockLocationName.isEmpty
                          ? "Minerals you own anywhere, plus ore at your refinery"
                          : "Minerals at \(stockLocationName), plus ore at your refinery")
                Toggle("Use stock at other stations", isOn: $useElsewhere)
                    .disabled(!subtractStock || stockLocationId <= 0)
                    .padding(.leading, 16)
                    .help(stockLocationId <= 0
                          ? "No Stock location is set in Build settings, so everything you own already counts."
                          : "Also count what you own at stations other than \(stockLocationName). It's listed under \"Fetch from Other Stations\" so you know to haul it before you build.")
            }

            Section("Add") {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(ownedOnly ? "Search your blueprints" : "Search anything buildable", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                Toggle("Only my blueprints", isOn: $ownedOnly)
                    .help("Ticked: just the blueprints you own – the search looks only through those")
                if !ownedOnly && searchText.trimmingCharacters(in: .whitespaces).count < 2 {
                    Picker("Category", selection: $browseCategory) {
                        Text("All").tag("")
                        ForEach(categories) { item in Text(item.name).tag(item.name) }
                        if !categories.contains(where: { $0.name == browseCategory }) && !browseCategory.isEmpty {
                            Text(browseCategory).tag(browseCategory)
                        }
                    }
                    .onChange(of: browseCategory) { _, _ in browseGroup = "" }
                    Picker("Group", selection: $browseGroup) {
                        Text("All").tag("")
                        ForEach(browseGroups) { item in Text(item.name).tag(item.name) }
                        if !browseGroups.contains(where: { $0.name == browseGroup }) && !browseGroup.isEmpty {
                            Text(browseGroup).tag(browseGroup)
                        }
                    }
                    .disabled(browseCategory.isEmpty)
                }
                if addList.isEmpty {
                    Text(ownedOnly ? "None of your blueprints match." : "Nothing matches.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(addList) { product in
                    Button {
                        names[product.blueprintTypeId] = product.productName
                        if !lines.contains(where: { $0.blueprintTypeID == product.blueprintTypeId }) {
                            save(lines + [Line(blueprintTypeID: product.blueprintTypeId, runs: 1)])
                        }
                    } label: {
                        HStack(spacing: 6) {
                            AsyncImage(url: PublicESIClient.typeIconURL(typeID: product.productTypeId, size: 32)) { image in
                                image.resizable()
                            } placeholder: { Color.clear }
                            .frame(width: 18, height: 18)
                            Text(product.productName)
                                .fontWeight(ownedIDs.contains(product.blueprintTypeId) ? .semibold : .regular)
                            Spacer()
                            if ownedIDs.contains(product.blueprintTypeId) && !ownedOnly {
                                Text("Owned").font(.caption2).foregroundStyle(.secondary)
                            }
                            Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Right: the plan

    @ViewBuilder
    private var results: some View {
        if lines.isEmpty {
            ContentUnavailableView("Plan a Build", systemImage: "cube.transparent",
                                   description: Text("Add what you want to build on the left. The planner breaks it down into components, works out the ore with the fewest m³ for the minerals (using your refinery yields), and lists and prices everything else you'd need."))
        } else if let plan {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 12) {
                        moneyTiles(plan)
                        HStack(spacing: 12) {
                            tile("Ore to Mine", "\(Int(plan.totalM3.rounded()).short) m³",
                                 detail: "fewest m³ that covers it (as Standard ore)")
                            tile("Units", plan.totalUnits.short, detail: "\(plan.ores.count) kinds of ore · fewer if graded")
                            tile("Building", "\(plan.items.reduce(0) { $0 + $1.units }.short) items",
                                 detail: plan.items.map { "\($0.units)× \($0.productName)" }.joined(separator: ", "))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isPlanning { ProgressView().controlSize(.small).padding(6) }
                    }

                    ForEach(plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ore to Mine").font(.headline)
                        if plan.ores.isEmpty {
                            Text(plan.minerals.contains { $0.toMine > 0 }
                                 ? "No ore in the list gives what's missing."
                                 : "You already have every mineral you need – nothing to mine.")
                                .foregroundStyle(.secondary)
                        } else {
                            Table(plan.ores.sorted(using: oreSort), selection: highlight.row("t353"), sortOrder: $oreSort) {
                                TableColumn("Ore", value: \.family) { ore in
                                    HStack(spacing: 6) {
                                        AsyncImage(url: PublicESIClient.typeIconURL(typeID: ore.typeId, size: 32)) { image in
                                            image.resizable()
                                        } placeholder: { Color.clear }
                                        .frame(width: 18, height: 18)
                                        Text(ore.family)
                                    }
                                    .help("Your yield \(ore.yield.percent) – the same for every grade of \(ore.family)")
                                }
                                .width(min: 110, ideal: 140)
                                TableColumn("Standard", value: \.standardUnits) { ore in
                                    gradeCell(ore.variant("Standard"), fallbackUnits: ore.units, m3: ore.m3)
                                }
                                TableColumn("II-Grade", value: \.gradeIIUnits) { ore in
                                    gradeCell(ore.variant("II-Grade"))
                                }
                                TableColumn("III-Grade", value: \.gradeIIIUnits) { ore in
                                    gradeCell(ore.variant("III-Grade"))
                                }
                                TableColumn("m³ (Standard)", value: \.m3) { Text(Int($0.m3.rounded()).short).monospacedDigit() }
                                TableColumn("Gives") { ore in
                                    Text(ore.givesText).lineLimit(1).help(ore.gives.map { "\($0.quantity.short) \($0.name)" }.joined(separator: "\n"))
                                }
                                .width(min: 160, ideal: 240)
                                TableColumn("In Belts") { ore in
                                    if let security = ore.security {
                                        Text("\(securityLabel(security)) · \(ore.space ?? "")").foregroundStyle(securityColor(security))
                                    } else {
                                        Text(ore.space ?? "–").foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contextMenu(forSelectionType: PlannedOre.ID.self) { ids in
                                if let id = ids.first, let ore = plan.ores.first(where: { $0.id == id }) {
                                    ItemMenu(typeID: ore.typeId, name: ore.name)
                                }
                            }
                            .frame(height: CGFloat(plan.ores.count) * 26 + 30)
                            .scrollDisabled(true)
                        }
                    }

                    if !plan.ores.isEmpty {
                        Text("Each grade column is enough on its own – mine whichever the belt has. Graded ore gives more minerals per unit, so you need fewer units of it. Mixing is fine: e.g. half the Standard amount plus half the II-Grade amount.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Minerals").font(.headline)
                        Table(plan.minerals, selection: highlight.row("t405")) {
                            TableColumn("Mineral") { m in
                                HStack(spacing: 6) {
                                    AsyncImage(url: PublicESIClient.typeIconURL(typeID: m.typeId, size: 32)) { image in
                                        image.resizable()
                                    } placeholder: { Color.clear }
                                    .frame(width: 18, height: 18)
                                    Text(m.name)
                                }
                            }
                            TableColumn("Needed") { Text($0.needed.short).monospacedDigit() }
                            TableColumn("Have") { Text($0.have.short).monospacedDigit().foregroundStyle(.secondary) }
                            TableColumn("To Mine") { m in
                                Text(m.toMine.short).monospacedDigit().fontWeight(m.toMine > 0 ? .semibold : .regular)
                            }
                            TableColumn("Plan Gives") { m in
                                Text(m.planGives.short).monospacedDigit()
                                    .foregroundStyle(m.planGives < m.toMine ? Color.red : Color.green)
                            }
                            TableColumn("Spare") { Text($0.spare.short).monospacedDigit().foregroundStyle(.secondary) }
                            TableColumn("Worth") { m in
                                Text(m.value.map { $0.short } ?? "–").monospacedDigit().foregroundStyle(.secondary)
                                    .help(m.unitPrice.map { "To Mine × \($0.short) each (\(plan.priceHub ?? "hub") buy orders)" } ?? "No price")
                            }
                        }
                        .contextMenu(forSelectionType: PlannedMineral.ID.self) { ids in
                            if let id = ids.first, let mineral = plan.minerals.first(where: { $0.id == id }) {
                                ItemMenu(typeID: mineral.typeId, name: mineral.name, quantity: mineral.toMine > 0 ? mineral.toMine : mineral.needed)
                            }
                        }
                        .frame(height: CGFloat(max(plan.minerals.count, 1)) * 26 + 30)
                        .scrollDisabled(true)
                        Text("Spare = extra minerals the ore gives beyond what you need (ore comes in whole batches and gives several minerals at once).")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if let away = plan.fromElsewhere, !away.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Fetch from Other Stations").font(.headline)
                            Text("You already own these, but not at \(stockLocationName.isEmpty ? "your Stock location" : stockLocationName). The plan counts them – haul them over before you build.")
                                .font(.caption).foregroundStyle(.secondary)
                            Table(away, selection: highlight.row("elsewhere")) {
                                TableColumn("Item") { row in
                                    Text(row.name)
                                        .contextMenu { ItemMenu(typeID: row.typeId, name: row.name) }
                                }
                                TableColumn("Quantity") { row in Text(row.quantity.formatted()).monospacedDigit() }
                                    .width(min: 70, ideal: 90)
                                TableColumn("Where") { row in
                                    Text(row.location)
                                        .contextMenu { PlaceMenu(locationID: row.locationId, name: row.location) }
                                }
                            }
                            .frame(height: CGFloat(away.count) * 26 + 30)
                            .scrollDisabled(true)
                        }
                    }

                    if let parts = plan.buildFirst, !parts.isEmpty {
                        let owned = plan.ownedComponentBlueprints ?? parts.filter(\.owned).count
                        DisclosureGroup(isExpanded: $showBuildFirst) {
                            Text("Built from the minerals above and the items below – their materials are already in the plan.")
                                .font(.caption).foregroundStyle(.secondary)
                            Table(parts.sorted(using: buildSort), selection: highlight.row("t446"), sortOrder: $buildSort) {
                                TableColumn("Component", value: \.name) { Text($0.name) }
                                    .width(min: 160, ideal: 240)
                                TableColumn("Blueprint", value: \.ownedSort) { part in
                                    Text(part.owned ? "✓ ME \(part.me)" : "✗ not owned")
                                        .foregroundStyle(part.owned ? Color.green : Color.orange)
                                }
                                TableColumn("Needed", value: \.needed) { Text($0.needed.short).monospacedDigit() }
                                TableColumn("Have", value: \.have) { Text($0.have.short).monospacedDigit().foregroundStyle(.secondary) }
                                TableColumn("To Build", value: \.toBuild) { part in
                                    Text(part.toBuild > 0 ? part.toBuild.short : "covered").monospacedDigit()
                                        .fontWeight(part.toBuild > 0 ? .semibold : .regular)
                                        .foregroundStyle(part.toBuild > 0 ? Color.primary : Color.secondary)
                                }
                                TableColumn("Runs", value: \.runs) { Text($0.runs.short).monospacedDigit() }
                            }
                            .contextMenu(forSelectionType: BuildFirstItem.ID.self) { ids in
                                if let id = ids.first, let part = parts.first(where: { $0.id == id }) {
                                    ItemMenu(typeID: part.typeId, name: part.name, quantity: part.toBuild > 0 ? part.toBuild : part.needed)
                                }
                            }
                            .frame(height: CGFloat(min(parts.count, 15)) * 26 + 30)
                        } label: {
                            Text("Build First – \(parts.count) component\(parts.count == 1 ? "" : "s") · you own \(owned) of the blueprints")
                                .font(.headline)
                        }
                    }

                    if !plan.otherMaterials.isEmpty {
                        let groups = Dictionary(grouping: plan.otherMaterials) { $0.source ?? "buy" }
                        ForEach(OtherMaterial.sourceOrder.filter { groups[$0] != nil }, id: \.self) { source in
                            let rows = groups[source] ?? []
                            let total = rows.reduce(0.0) { $0 + ($1.value ?? 0) }
                            DisclosureGroup(isExpanded: Binding(
                                get: { openSources.contains(source) },
                                set: { open in if open { openSources.insert(source) } else { openSources.remove(source) } }
                            )) {
                                Table(rows.sorted(using: buySort), selection: highlight.row("t483"), sortOrder: $buySort) {
                                    TableColumn("Item", value: \.name) { Text($0.name) }
                                        .width(min: 160, ideal: 240)
                                    TableColumn("Needed", value: \.needed) { Text($0.needed.short).monospacedDigit() }
                                    TableColumn("Have", value: \.have) { Text($0.have.short).monospacedDigit().foregroundStyle(.secondary) }
                                    TableColumn("To Get", value: \.toGet) { m in
                                        Text(m.toGet.short).monospacedDigit()
                                            .fontWeight(m.toGet > 0 ? .semibold : .regular)
                                            .foregroundStyle(m.toGet > 0 ? Color.orange : Color.secondary)
                                    }
                                    TableColumn("Price", value: \.priceSort) { Text($0.unitPrice.map { $0.short } ?? "–").monospacedDigit() }
                                    TableColumn("Cost", value: \.valueSort) { Text($0.value.map { $0.short } ?? "–").monospacedDigit() }
                                }
                                .contextMenu(forSelectionType: OtherMaterial.ID.self) { ids in
                                    if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                                        ItemMenu(typeID: row.typeId, name: row.name, quantity: row.toGet > 0 ? row.toGet : row.needed)
                                    }
                                }
                                .frame(height: CGFloat(min(rows.count, 15)) * 26 + 30)
                            } label: {
                                Text("\(OtherMaterial.sourceTitle(source)) · \(rows.count) item\(rows.count == 1 ? "" : "s")" + (total > 0 ? " · ≈ \(total.short)" : ""))
                                    .font(.headline)
                            }
                        }
                        Text("Prices: the cheapest sell order at \(plan.priceHub ?? "the hub") (what you'd pay), or CCP's average price when there's none.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        } else if let errorMessage {
            ContentUnavailableView("Couldn't Plan", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else {
            ProgressView("Working out the best ore mix…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Units of one grade, with batches and m³ in the tooltip.
    @ViewBuilder
    private func gradeCell(_ variant: OreVariant?, fallbackUnits: Int? = nil, m3: Double? = nil) -> some View {
        if let variant {
            Text(variant.units.short)
                .monospacedDigit()
                .help("\(variant.name): \(variant.batches.short) batches · \(Int(variant.m3.rounded()).short) m³\nGives " + variant.gives.map { "\($0.quantity.short) \($0.name)" }.joined(separator: ", "))
        } else if let fallbackUnits {
            Text(fallbackUnits.short).monospacedDigit()
                .help(m3.map { "\(Int($0.rounded()).short) m³" } ?? "")
        } else {
            Text("–").foregroundStyle(.secondary)
                .help("No belt grade of this ore in the areas you picked")
        }
    }

    // MARK: Money

    private static func percent(_ value: Double) -> String {
        String(format: "%+.1f%%", value * 100)
    }

    private static func signed(_ value: Double) -> String {
        (value >= 0 ? "+" : "−") + abs(value).short
    }

    private func sellPlace(_ money: PlanMoney) -> String {
        let hubs = Set((money.items ?? []).compactMap(\.sellHub))
        if hubs.count == 1, let only = hubs.first { return only }
        return "the best of the five hubs"
    }

    /// Total Cost · Sells For · Profit – the same sums as Build vs Sell.
    @ViewBuilder
    private func moneyTiles(_ plan: BuildPlan) -> some View {
        if let money = plan.economics, let cost = money.cost {
            HStack(spacing: 12) {
                tile("Total Cost", "≈ \(cost.short)", detail: costDetail(money))
                    .help(originNote(plan) + "Minerals (mined or from stock) at what they'd sell for in \(plan.priceHub ?? "the hub")'s buy orders after tax – the same as Build vs Sell. Everything else at its cheapest sell order. \(breakDown ? "Components are built: their own materials plus their job fees." : "Components are bought.")")
                if let sells = money.sellsFor {
                    tile("Sells For", "≈ \(sells.short)", detail: "at \(sellPlace(money)), after sales tax and broker fee")
                        .help("Price-checked against recent sales, like Build vs Sell. The sell hub is the one chosen on Build vs Sell.")
                } else {
                    tile("Sells For", "–", detail: "\(money.unsoldCount ?? 0) item(s) have no sell orders to price")
                }
                profitTile(money)
            }
        }
    }

    /// When stock-origin tracking began – stock owned then counts as "already had".
    private func originNote(_ plan: BuildPlan) -> String {
        if plan.originStartedNow == true {
            return "Stock tracking started just now: everything you own today counts as \"already had\". From now on, things that turn up without being bought, mined or built count as \"looted / other\". "
        }
        if let since = plan.originSince, let date = ISO8601DateFormatter().date(from: since) {
            return "Stock tracked since \(date.formatted(date: .abbreviated, time: .omitted)) – what you owned then counts as \"already had\"; anything that turned up since without being bought, mined or built counts as \"looted / other\". "
        }
        return ""
    }

    /// "Minerals · Bought · Job fees", then where the stock minerals came from.
    private func costDetail(_ money: PlanMoney) -> String {
        var text = "Minerals \((money.costMinerals ?? 0).short) · Bought \((money.costBought ?? 0).short) · Job fees \((money.costFees ?? 0).short)"
        let boughtValue = money.stockBoughtValue ?? 0
        let freeValue = money.stockFreeValue ?? 0
        if boughtValue + freeValue >= 1 {
            var parts: [String] = []
            if boughtValue >= 1 { parts.append("\(boughtValue.short) bought or built (cost you \((money.stockPaid ?? 0).short))") }
            let mined = money.stockMinedValue ?? 0
            let other = money.stockOtherValue ?? 0
            let had = money.stockHadValue ?? 0
            if mined + other + had >= 1 {
                if mined >= 1 { parts.append("\(mined.short) mined") }
                if other >= 1 { parts.append("\(other.short) looted / other") }
                if had >= 1 { parts.append("\(had.short) already had") }
            } else if freeValue >= 1 {
                parts.append("\(freeValue.short) mined, looted or had")
            }
            text += "\nFrom stock: " + parts.joined(separator: " · ")
        }
        return text
    }

    @ViewBuilder
    private func profitTile(_ money: PlanMoney) -> some View {
        let profit = money.profit
        VStack(alignment: .leading, spacing: 4) {
            Text("Profit").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(profit.map { Self.signed($0) } ?? "–")
                    .font(.title2).bold().monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if let pct = money.profitPercent {
                    Text(Self.percent(pct)).font(.callout).monospacedDigit()
                }
            }
            .foregroundStyle(profit.map { $0 >= 0 ? Color.green : Color.red } ?? Color.secondary)
            if let cash = money.cashProfit {
                Text("Cash profit: \(Self.signed(cash))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("Only the ISK you actually spend: what you still have to buy, the job fees, and stock at what it cost you (bought at what you paid, built at what the build cost). Minerals you mine, and stock you mined, looted or already had, count as free. The Profit above values every mineral at what you could sell it for instead – that's the one that tells you whether building beats selling the minerals.")
            }
            if let saves = money.buildingComponentsSaves, abs(saves) >= 1 {
                Text(saves >= 0 ? "Building the components yourself saves \(saves.short)"
                                : "Buying the components would save \(abs(saves).short)")
                    .font(.caption).foregroundStyle(saves >= 0 ? Color.secondary : Color.orange).lineLimit(1)
                    .help("Compares building every component yourself with buying them at the hub – whichever way \"Build components myself\" is set.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Small line under each item on the left: cost · sells for · profit.
    @ViewBuilder
    private func itemMoneyLine(_ blueprintTypeID: Int) -> some View {
        if let m = plan?.economics?.items?.first(where: { $0.blueprintTypeId == blueprintTypeID }), let cost = m.cost {
            HStack(spacing: 4) {
                Text("Cost \(cost.short)")
                if let sells = m.sellsFor { Text("· Sells \(sells.short)") }
                if let profit = m.profit {
                    Text("· \(Self.signed(profit))\(m.profitPercent.map { " (\(Self.percent($0)))" } ?? "")")
                        .foregroundStyle(profit >= 0 ? Color.green : Color.red)
                } else {
                    Text("· no sell price")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    private func tile(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).bold().monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Planning

    private func makePlan() async {
        guard !lines.isEmpty else {
            plan = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(300)) // let stepper clicks settle
        guard !Task.isCancelled else { return }
        isPlanning = true
        defer { isPlanning = false }

        var query: [URLQueryItem] = [
            URLQueryItem(name: "items", value: itemsText),
            URLQueryItem(name: "structure", value: structure),
            URLQueryItem(name: "rig_me", value: String(rigME)),
            URLQueryItem(name: "subtract_stock", value: subtractStock ? "true" : "false"),
            URLQueryItem(name: "break_down", value: breakDown ? "true" : "false"),
            URLQueryItem(name: "spaces", value: spaces),
            URLQueryItem(name: "hub", value: materialHub),
            URLQueryItem(name: "system_id", value: String(systemId)),
            URLQueryItem(name: "facility_tax", value: String(facilityTax)),
            URLQueryItem(name: "sell_hub", value: sellHub),
            URLQueryItem(name: "use_elsewhere", value: useElsewhere ? "true" : "false"),
        ]
        if stockLocationId > 0 {
            query.append(URLQueryItem(name: "stock_location", value: String(stockLocationId)))
        }
        if useOre && refineryId > 0 {
            query.append(URLQueryItem(name: "refinery_location", value: String(refineryId)))
        }
        query.append(contentsOf: BuildSettingsKey.refineryQuery())

        do {
            let newPlan = try await appState.backend.buildPlan(query)
            guard !Task.isCancelled else { return }
            plan = newPlan
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
