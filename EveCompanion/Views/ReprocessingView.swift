import SwiftUI

/// Ore and ice sitting at your refinery: what it reprocesses into, and whether to reprocess or sell.
struct ReprocessingView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(BuildSettingsKey.refineryId) private var refineryId = 0
    @AppStorage(BuildSettingsKey.refineryName) private var refineryName = ""
    @AppStorage(BuildSettingsKey.oreYield) private var oreYield = BuildSettingsKey.defaultOreYield
    @AppStorage(BuildSettingsKey.oreYieldSkill) private var oreYieldSkill = BuildSettingsKey.defaultOreYieldSkill
    @AppStorage(BuildSettingsKey.iceYield) private var iceYield = BuildSettingsKey.defaultIceYield
    @AppStorage(BuildSettingsKey.refineryTax) private var refineryTax = BuildSettingsKey.defaultRefineryTax
    @AppStorage(BuildSettingsKey.materialHub) private var materialHub = BuildSettingsKey.defaultHub
    @AppStorage(BuildSettingsKey.materialPrice) private var materialPrice = "buy"

    @State private var summary: ReproSummary?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var refreshCounter = 0
    @State private var showSettings = false
    @State private var selectedOreID: ReproOre.ID?
    @AppStorage("reprocessing.hideSmallStacks") private var hideSmallStacks = false
    @AppStorage(PriceCheckKey.band) private var priceBand = 50
    @AppStorage(PriceCheckKey.lookbackDays) private var lookbackDays = 30
    @State private var oreSort = [KeyPathComparator(\ReproOre.name)]
    @State private var mineralSort = [KeyPathComparator(\ReproOutput.quantity, order: .reverse)]
    @State private var outputSort = [KeyPathComparator(\ReproOutput.quantity, order: .reverse)]

    private struct LoadKey: Hashable {
        var refineryId: Int
        var oreYield: Double
        var oreYieldSkill: String
        var iceYield: Double
        var refineryTax: Double
        var hub: String
        var price: String
        var priceBand: Int
        var lookbackDays: Int
        var refresh: Int
    }

    private var loadKey: LoadKey {
        LoadKey(refineryId: refineryId, oreYield: oreYield, oreYieldSkill: oreYieldSkill, iceYield: iceYield,
                refineryTax: refineryTax, hub: materialHub, price: materialPrice,
                priceBand: priceBand, lookbackDays: lookbackDays, refresh: refreshCounter)
    }

    var body: some View {
        Group {
            if refineryId == 0 {
                ContentUnavailableView {
                    Label("Choose Your Refinery", systemImage: "arrow.3.trianglepath")
                } description: {
                    Text("Pick the station or structure where you reprocess ore in Build Settings, and enter the yield the game shows you there.")
                } actions: {
                    Button("Open Build Settings") { showSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if let summary {
                content(summary)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Ore", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { refreshCounter += 1 }
                }
            } else {
                ProgressView("Reading your ore and fetching \(materialHub) prices…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(refineryName)
        .inspector(isPresented: $showSettings) {
            BuildSettingsView()
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .toolbar {
            ToolbarItemGroup {
                if isLoading && summary != nil {
                    ProgressView().controlSize(.small)
                }
                Button {
                    refreshCounter += 1
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Re-read your assets and prices")
                Button {
                    showSettings.toggle()
                } label: {
                    Label("Settings", systemImage: "sidebar.right")
                }
                .help("Refinery & price settings")
            }
        }
        .task(id: loadKey) { await load() }
    }

    // MARK: - Content

    private func content(_ summary: ReproSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if summary.ores.isEmpty {
                    ContentUnavailableView(
                        "No Ore Here",
                        systemImage: "cube.transparent",
                        description: Text("There's no ore or ice at \(refineryName.isEmpty ? "this station" : refineryName) right now (assets refresh every 10 minutes).")
                    )
                } else {
                    tiles(summary)
                    oreTable(summary)
                    if let ore = summary.ores.first(where: { $0.id == selectedOreID }) {
                        oreDetail(ore, summary: summary)
                    } else {
                        mineralTable(summary)
                    }
                    explanation(summary)
                }
            }
            .padding(20)
        }
    }

    private func tiles(_ summary: ReproSummary) -> some View {
        let difference = summary.totalValueAsMinerals - summary.totalValueAsOre
        return HStack(alignment: .top, spacing: 12) {
            Tile(title: "Sell as Ore", value: summary.totalValueAsOre.iskShort,
                 detail: "\(summary.hub) \(summary.price) orders")
            Tile(title: "Reprocess & Sell Minerals", value: summary.totalValueAsMinerals.iskShort,
                 detail: "after ~\(refineryTax.formatted())% refinery tax (\(summary.totalTax.iskShort))")
            Tile(title: difference >= 0 ? "Reprocessing Gains" : "Selling Ore Gains",
                 value: abs(difference).iskShort,
                 detail: difference >= 0 ? "Reprocess before selling or building" : "Ore is worth more unrefined",
                 color: difference >= 0 ? .green : .orange)
        }
    }

    /// The "?" key: what each column means.
    static let columnKey: [(String, String)] = [
        ("Ore", "Ore you have at the refinery."),
        ("Quantity", "Units of it."),
        ("Yield", "Share of the minerals you get back (refinery × your skills)."),
        ("Reprocesses Into", "Minerals it gives you."),
        ("Ore Sell Value", "Cash from selling the ore as it is, after selling fees."),
        ("Minerals Sell Value", "Cash from reprocessing and selling the minerals, after refinery tax and selling fees."),
        ("Best", "Whichever of the two pays more."),
        ("Unit Price / Value", "Price of one mineral (after the price check) · that times the quantity."),
        ("Reprocessing Cost / Net", "Refinery tax on that mineral · its value after the tax."),
    ]

    private func oreTable(_ summary: ReproSummary) -> some View {
        let ores = (hideSmallStacks ? summary.ores.filter { !$0.tooSmall } : summary.ores).sorted(using: oreSort)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ore at \(refineryName.isEmpty ? "Refinery" : refineryName)").font(.headline)
                Spacer()
                Toggle("Hide stacks too small to reprocess", isOn: $hideSmallStacks)
                    .toggleStyle(.checkbox)
                PriceCheckMenu(showBatch: false)
                PageKeyButton(columns: Self.columnKey)
            }
            Text("Click an ore to see what it reprocesses into and what that costs.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Table(ores, selection: $selectedOreID, sortOrder: $oreSort) {
                TableColumn("Ore", value: \.name) { ore in
                    HStack(spacing: 6) {
                        AsyncImage(url: PublicESIClient.typeIconURL(typeID: ore.typeId, size: 32)) { image in
                            image.resizable()
                        } placeholder: { Color.clear }
                        .frame(width: 18, height: 18)
                        Text(ore.name)
                    }
                }
                .width(min: 150, ideal: 180)
                TableColumn("Quantity", value: \.quantity) { ore in
                    Text(ore.quantity.short).monospacedDigit()
                        .help(ore.leftover > 0 ? "\(ore.leftover) units left over (not a full batch)" : "")
                }
                TableColumn("Yield", value: \.yieldRate) { ore in
                    Text(ore.yieldRate.percent).monospacedDigit()
                        .help("\(ore.skill ?? "No specific skill") level \(ore.skillLevel)")
                }
                TableColumn("Reprocesses Into", value: \.outputsSort) { ore in
                    Text(ore.outputs.map { "\($0.quantity.short) \($0.name)" }.joined(separator: ", "))
                        .lineLimit(1)
                        .help(ore.outputs.map { "\($0.quantity.short) \($0.name)" }.joined(separator: "\n"))
                }
                .width(min: 160, ideal: 240)
                TableColumn("Ore Sell Value", value: \.valueAsOre) { ore in
                    HStack(spacing: 4) {
                        Text(ore.valueAsOre.iskShort).monospacedDigit()
                            .foregroundStyle(ore.tooSmall ? Color.secondary : (ore.valueAsOre >= ore.valueAsMinerals ? Color.green : Color.primary))
                            .help("Cash to your wallet selling all \(ore.quantity.short) units as ore at \(ore.oreUnitPrice.isk) each (\(summary.hub) \(summary.price) orders, checked against the fair price), after selling fees.")
                        PriceBadgesView(badges: PriceBadge.badges(
                            ore.oreCheck, place: summary.hub, lookback: summary.lookbackDays ?? lookbackDays,
                            what: "Selling \(ore.quantity.short)", sellSide: summary.price == "sell"))
                    }
                }
                .width(min: 110, ideal: 180)
                TableColumn("Minerals Sell Value", value: \.mineralsValueSort) { ore in
                    Text(ore.tooSmall ? "–" : ore.valueAsMinerals.iskShort).monospacedDigit()
                        .foregroundStyle(ore.tooSmall ? Color.secondary : (ore.valueAsMinerals > ore.valueAsOre ? Color.green : Color.primary))
                        .help("Cash to your wallet reprocessing this ore and selling the minerals at \(summary.hub) \(summary.price) orders, after refinery tax and selling fees." + (ore.outputs.contains(where: { $0.priceFlagged }) ? "\nSome mineral prices failed the price check – see the minerals below." : ""))
                }
                TableColumn("Best", value: \.bestSort) { ore in
                    if ore.tooSmall {
                        Text("Need \(ore.portionSize ?? 100) to reprocess")
                            .foregroundStyle(.secondary)
                    } else if ore.better == "reprocess" {
                        Label("Reprocess", systemImage: "arrow.3.trianglepath").foregroundStyle(.green)
                    } else {
                        Label("Sell Ore", systemImage: "cart").foregroundStyle(.orange)
                    }
                }
            }
            .contextMenu(forSelectionType: ReproOre.ID.self) { ids in
                if let id = ids.first, let ore = ores.first(where: { $0.id == id }) {
                    ItemMenu(typeID: ore.typeId, name: ore.name)
                }
            }
            .frame(height: CGFloat(ores.count) * 26 + 30)
            .scrollDisabled(true)
        }
    }

    private func mineralTable(_ summary: ReproSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Minerals From All Ore Combined").font(.headline)
            Table(summary.minerals.sorted(using: mineralSort), sortOrder: $mineralSort) {
                TableColumn("Mineral", value: \.name) { mineral in
                    HStack(spacing: 6) {
                        AsyncImage(url: PublicESIClient.typeIconURL(typeID: mineral.typeId, size: 32)) { image in
                            image.resizable()
                        } placeholder: { Color.clear }
                        .frame(width: 18, height: 18)
                        Text(mineral.name)
                    }
                }
                TableColumn("Quantity", value: \.quantity) { mineral in
                    Text(mineral.quantity.short).monospacedDigit()
                }
                TableColumn("Unit Price", value: \.unitPrice) { mineral in
                    HStack(spacing: 4) {
                        Text(mineral.unitPrice.isk).monospacedDigit()
                        PriceBadgesView(badges: PriceBadge.badges(
                            mineral.check, place: summary.hub, lookback: summary.lookbackDays ?? lookbackDays,
                            what: "Selling \(mineral.quantity.short)", sellSide: summary.price == "sell"))
                    }
                }
                .width(min: 110, ideal: 200)
                TableColumn("Value", value: \.value) { mineral in
                    Text(mineral.value.iskShort).monospacedDigit()
                }
            }
            .contextMenu(forSelectionType: ReproOutput.ID.self) { ids in
                if let id = ids.first, let mineral = summary.minerals.first(where: { $0.id == id }) {
                    ItemMenu(typeID: mineral.typeId, name: mineral.name)
                }
            }
            .frame(height: CGFloat(summary.minerals.count) * 26 + 30)
            .scrollDisabled(true)
        }
    }

    /// Breakdown for the ore selected in the table above.
    private func oreDetail(_ ore: ReproOre, summary: ReproSummary) -> some View {
        var info = "Yield \(ore.yieldRate.percent)"
        if let skill = ore.skill {
            info += " · \(skill) \(ore.skillLevel.roman)"
        }
        if ore.leftover > 0 {
            info += " · \(ore.leftover.short) units left over (not a full batch)"
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reprocessing \(ore.quantity.short) \(ore.name)").font(.headline)
                Spacer()
                Button("Show All Ore") { selectedOreID = nil }
                    .buttonStyle(.link)
            }
            Text(info)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                Tile(title: "Minerals Value", value: ore.mineralsValue.iskShort,
                     detail: "\(summary.hub) \(summary.price) orders")
                Tile(title: "Reprocessing Cost", value: ore.tax.iskShort,
                     detail: "\(refineryTax.formatted())% refinery tax", color: .orange)
                Tile(title: "You Get", value: ore.valueAsMinerals.iskShort,
                     detail: "vs \(ore.valueAsOre.iskShort) selling it as ore",
                     color: ore.valueAsMinerals >= ore.valueAsOre ? .green : .orange)
            }

            Table(ore.outputs.sorted(using: outputSort), sortOrder: $outputSort) {
                TableColumn("Mineral", value: \.name) { mineral in
                    HStack(spacing: 6) {
                        AsyncImage(url: PublicESIClient.typeIconURL(typeID: mineral.typeId, size: 32)) { image in
                            image.resizable()
                        } placeholder: { Color.clear }
                        .frame(width: 18, height: 18)
                        Text(mineral.name)
                    }
                }
                .width(min: 120, ideal: 160)
                TableColumn("Quantity", value: \.quantity) { mineral in
                    Text(mineral.quantity.short).monospacedDigit()
                }
                TableColumn("Unit Price", value: \.unitPrice) { mineral in
                    Text(mineral.unitPrice.isk).monospacedDigit()
                        .foregroundStyle(mineral.priceFlagged ? Color.orange : Color.primary)
                        .help(mineral.priceFlagged ? "This price failed the price check – see Minerals From All Ore Combined." : "")
                }
                TableColumn("Value", value: \.value) { mineral in
                    Text(mineral.value.iskShort).monospacedDigit()
                }
                TableColumn("Reprocessing Cost", value: \.taxSort) { mineral in
                    Text((mineral.tax ?? 0).iskShort)
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
                TableColumn("Net", value: \.net) { mineral in
                    Text(mineral.net.iskShort)
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
            }
            .contextMenu(forSelectionType: ReproOutput.ID.self) { ids in
                if let id = ids.first, let mineral = ore.outputs.first(where: { $0.id == id }) {
                    ItemMenu(typeID: mineral.typeId, name: mineral.name)
                }
            }
            .frame(height: CGFloat(ore.outputs.count) * 26 + 30)
            .scrollDisabled(true)
        }
    }

    private func explanation(_ summary: ReproSummary) -> some View {
        DisclosureGroup("How yields are worked out") {
            VStack(alignment: .leading, spacing: 6) {
                if oreYield == 0 {
                    Text("You haven't entered a yield from your refinery yet, so a plain NPC station is assumed (refinery bonus 50%). Each ore's yield is that bonus × your Reprocessing \(summary.reprocessingLevel.roman), Reprocessing Efficiency \(summary.efficiencyLevel.roman) and the ore's own processing skill. Enter the yield the game shows in Build Settings for exact figures.")
                } else {
                    Text("From the \(oreYield.formatted())% you read in-game (measured on \(oreYieldSkill.replacingOccurrences(of: " Processing", with: "")) ore), your skills are divided out to get the refinery's own bonus: ore \(summary.oreFactor.percent), ice \(summary.iceFactor.percent). Each ore's yield is that bonus × your Reprocessing \(summary.reprocessingLevel.roman), Reprocessing Efficiency \(summary.efficiencyLevel.roman) and the ore's own processing skill.")
                }
                Text("Game rounds the % it shows, so totals can differ from the game by about 0.05%. Minerals and ore are both valued at \(summary.hub) \(summary.price) orders.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
    }

    // MARK: - Loading

    private func load() async {
        guard refineryId != 0 else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }

        var query = BuildSettingsKey.refineryQuery()
        query.append(URLQueryItem(name: "location_id", value: String(refineryId)))
        query.append(URLQueryItem(name: "hub", value: materialHub))
        query.append(URLQueryItem(name: "price", value: materialPrice))
        do {
            let result = try await appState.backend.reprocessingSummary(query)
            guard !Task.isCancelled else { return }
            summary = result
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct Tile: View {
    let title: String
    let value: String
    let detail: String
    var color: Color = .primary

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold)).foregroundStyle(color)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
