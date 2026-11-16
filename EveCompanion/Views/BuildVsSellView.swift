import SwiftUI

// MARK: - Models (/reference/blueprint-categories, /reference/build-vs-sell)

struct BlueprintGroup: Decodable, Identifiable, Hashable {
    let name: String
    let count: Int
    var id: String { name }
}

struct BlueprintCategory: Decodable, Identifiable, Hashable {
    let name: String
    let count: Int
    let groups: [BlueprintGroup]
    var id: String { name }
}

struct BuildVsSellResult: Decodable {
    let pricesAsOf: Double?
    let materialHub: String
    let sellHub: String
    let salesTax: Double
    let costIndex: Double
    let total: Int
    let limit: Int
    let items: [BuildVsSellItem]
    let priceBand: Double?
    let lookbackDays: Int?
    let batchRuns: Int?
    /// Order books EVE's servers wouldn't give us this time (timeouts).
    let priceGaps: Int?
}

/// A material whose price failed the fair-price check.
struct MaterialFlag: Decodable {
    let name: String
    let status: String
}

struct MaterialNeed: Decodable {
    let name: String
    let quantity: Int
}

struct BuildVsSellItem: Decodable, Identifiable {
    let blueprintTypeId: Int
    let productTypeId: Int
    let name: String
    let group: String
    let category: String
    let tech: String
    let unitsPerRun: Int
    let owned: Bool
    let ownedIsCopy: Bool
    let me: Int
    let te: Int
    let materials: [MaterialNeed]
    let unpricedMaterials: Int
    let materialsIfSold: Double
    let jobFee: Double
    let buildSeconds: Double
    let bestHub: String?
    let sellPrice: Double?
    let productSale: Double?
    let competition: Int
    let gain: Double?
    let gainPerHour: Double?
    let gainPercent: Double?
    /// Gain per hour capped by your share of the market (sold per day ÷ sellers + you).
    let gainPerHourMarket: Double?
    let marketLimited: Bool?
    let sharePerDay: Double?
    let sellers: Int?
    let soldPerDay: Double?
    let averagePrice: Double?
    let historyHub: String?
    // Fair-price check (FairPrice.swift)
    let priceLive: Double?
    let priceUsed: Double?
    let fairPrice: Double?
    let priceStatus: String?
    let priceTrend: String?
    let thinMarket: Bool?
    let daysToSell: Double?
    let spread: String?
    /// The full sale-price check from the engine.
    let saleCheck: PriceCheck?
    let materialFlags: [MaterialFlag]?
    // History
    let watched: Bool?
    let mySoldUnits: Int?
    let mySoldValue: Double?
    let trend: CompetitionTrend?

    var id: Int { blueprintTypeId }

    var soldPerDaySort: Double { soldPerDay ?? -1 }
    var averagePriceSort: Double { averagePrice ?? -1 }
    var fairPriceSort: Double { fairPrice ?? -1 }

    /// Live (depth) price compared with the fair price: 1.3 = 30% above.
    var liveVsFair: Double? {
        guard let live = priceLive ?? sellPrice, let fairPrice, fairPrice > 0 else { return nil }
        return live / fairPrice
    }

    /// Why the price used differs from the live price (or why it's worth a second look).
    func priceBadges(lookback: Int, batchRuns: Int) -> [PriceBadge] {
        PriceBadge.badges(saleCheck, place: bestHub ?? historyHub ?? "the hub", lookback: lookback,
                          what: "A batch of \(batchRuns) run(s)", spread: spread)
    }

    func fairHelp(lookback: Int) -> String {
        let hub = historyHub ?? bestHub ?? "the hub"
        var text = "Median of daily sales over \(lookback) days in \(hub)'s region"
        if priceTrend != nil { text += " (last 7 days, as the market has clearly moved)" }
        let live = (priceLive ?? sellPrice)?.isk ?? "–"
        text += ".\nLive price for a batch: \(live)."
        if let averagePrice { text += "\nVolume-weighted average: \(averagePrice.isk)." }
        return text
    }

    var materialFlagText: String? {
        guard let flags = materialFlags, !flags.isEmpty else { return nil }
        let lines = flags.map { "\($0.name): \($0.status == "inflated" ? "buy orders look inflated – fair price used" : "buy orders look dumped – live price kept")" }
        return "Price check:\n" + lines.joined(separator: "\n")
    }

    /// Lowest sell order compared with the 30-day average traded price (1.3 = 30% above normal).
    var priceVsAverage: Double? {
        guard let sellPrice, let averagePrice, averagePrice > 0 else { return nil }
        return sellPrice / averagePrice
    }

    var daysToClear: Double? {
        guard let soldPerDay, soldPerDay > 0 else { return nil }
        return Double(competition) / soldPerDay
    }

    // Sort keys (nothing for sale anywhere → bottom).
    var gainSort: Double { gain ?? -.greatestFiniteMagnitude }
    var gainPerHourSort: Double { gainPerHour ?? -.greatestFiniteMagnitude }
    var gainPercentSort: Double { gainPercent ?? -.greatestFiniteMagnitude }
    var gainPerHourMarketSort: Double { gainPerHourMarket ?? -.greatestFiniteMagnitude }

    /// Within ±5% of the materials' value counts as "Either" – that's inside normal price noise.
    static let eitherBand = 0.05

    enum Verdict { case build, sell, either, unknown }

    var verdict: Verdict {
        guard let gainPercent else { return .unknown }
        if abs(gainPercent) < Self.eitherBand { return .either }
        return gainPercent > 0 ? .build : .sell
    }

    var verdictText: String {
        let percent = gainPercent.map { "\($0 >= 0 ? "+" : "−")\(abs($0).percent)" } ?? ""
        switch verdict {
        case .build: return "Build \(percent)"
        case .sell: return "Sell mats \(percent)"
        case .either: return "Either \(percent)"
        case .unknown: return "–"
        }
    }

    var verdictHelp: String {
        guard let gain else { return "Nothing for sale to compare with." }
        var text: String
        switch verdict {
        case .build: text = "Building beats selling the materials."
        case .sell: text = "Selling the materials beats building."
        case .either: text = "Within ±5% – too close to call, prices move more than that."
        case .unknown: text = ""
        }
        text += "\n\nFor the batch: sale \((productSale ?? 0).iskShort) − job fee \(jobFee.iskShort) − materials \(materialsIfSold.iskShort) = \(gain.iskShort)."
        if let gainPerHour {
            text += "\nPer hour of factory time: \(gainPerHour.iskShort)."
        }
        if let market = gainPerHourMarket {
            text += "\nPer hour, limited by what the market buys: \(market.iskShort)" + (marketLimited == true ? " – the market, not the factory, is the limit." : ".")
        }
        return text
    }

    var gainPerHourHelp: String {
        var text = "Gain per hour, capped by the market: you can only earn as fast as you can sell."
        if let share = sharePerDay {
            let shareText = share >= 10 ? share.short : String(format: "%.1f", share)
            text += "\nYour share ≈ \(shareText) a day (region sales ÷ \(sellers ?? 0) sellers + you)."
        }
        if let gainPerHour { text += "\nFactory alone: \(gainPerHour.iskShort) per hour." }
        text += "\nBuild time \(buildSeconds.durationLabel) for the batch."
        return text
    }
    var saleSort: Double { productSale ?? -.greatestFiniteMagnitude }
    var ownedSort: Int { owned ? 1 : 0 }

    var blueprintLabel: String {
        if owned { return "\(ownedIsCopy ? "BPC" : "BPO") · ME \(me)" }
        return tech == "T2" ? "Not owned · ME \(me)" : "Not owned"
    }

    var marketLabel: String {
        let sold = soldPerDay.map { $0 >= 10 ? $0.short : String(format: "%.1f", $0) } ?? "–"
        return "\(competition.short) · \(sold)/day"
    }

    var marketHelp: String {
        var text = "\(competition.short) listed at \(bestHub ?? historyHub ?? "the hub"); about \(soldPerDay.map { String(format: "%.1f", $0) } ?? "0") sold per day in its region (30-day average)."
        if let daysToClear { text += "\nAt that rate the listed stock clears in about \(Int(daysToClear.rounded())) days." }
        return text
    }

    /// Market tooltip plus competition trend and your own sales from the local history.
    func marketHelpWithHistory(range: String) -> String {
        var text = marketHelp
        if let trend { text += "\n\nCompetition at \(bestHub ?? historyHub ?? "the hub"): " + trend.description }
        if let units = mySoldUnits, units > 0 {
            text += "\n\nYou sold \(units.short) for \((mySoldValue ?? 0).iskShort) (\(range))."
        }
        return text
    }

    var materialList: String {
        var text = materials.map { "\($0.quantity.short) \($0.name)" }.joined(separator: "\n")
        if unitsPerRun > 1 { text = "Makes \(unitsPerRun) per run\n\n" + text }
        if tech == "T2" { text += "\n\nInvention cost not included." }
        if unpricedMaterials > 0 { text += "\n\(unpricedMaterials) material(s) have no buy orders – valued at CCP's adjusted price." }
        if let flags = materialFlagText { text += "\n\n" + flags }
        return text
    }
}

// MARK: - View

/// Reference: is building an item worth more than selling the materials it needs?
struct BuildVsSellView: View {
    @Environment(AppState.self) private var appState

    // Shared build settings (same as the Manufacturing page).
    @AppStorage(BuildSettingsKey.systemId) private var systemId = BuildSettingsKey.defaultSystemId
    @AppStorage(BuildSettingsKey.structure) private var structure = StructureKind.npc.rawValue
    @AppStorage(BuildSettingsKey.rigME) private var rigME = 0.0
    @AppStorage(BuildSettingsKey.rigTE) private var rigTE = 0.0
    @AppStorage(BuildSettingsKey.facilityTax) private var facilityTax = 0.25
    @AppStorage(BuildSettingsKey.materialHub) private var defaultMaterialHub = BuildSettingsKey.defaultHub

    @AppStorage("buildVsSell.category") private var category = "Ship"
    @AppStorage("buildVsSell.group") private var group = "Frigate"
    @AppStorage("buildVsSell.sellHub") private var sellHub = "best"
    @AppStorage("buildVsSell.materialHub") private var materialHub = ""
    @AppStorage("buildVsSell.defaultME") private var defaultME = 0
    @AppStorage("buildVsSell.ownedOnly") private var ownedOnly = false
    @AppStorage(PriceCheckKey.band) private var priceBand = 50
    @AppStorage(PriceCheckKey.lookbackDays) private var lookbackDays = 30
    @AppStorage(PriceCheckKey.batchRuns) private var batchRuns = 10

    @State private var search = ""
    @State private var categories: [BlueprintCategory] = []
    @State private var result: BuildVsSellResult?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var refreshCounter = 0
    @State private var selection: BuildVsSellItem.ID?
    @State private var watchOverrides: [Int: Bool] = [:]
    @AppStorage(HistoryRange.key) private var rangeDays = HistoryRange.defaultDays
    @State private var autoRefreshCounter = 0
    @State private var forceFresh = false
    @State private var sortOrder = [KeyPathComparator(\BuildVsSellItem.gainPercentSort, order: .reverse)]
    /// Column widths / order you set by dragging, remembered between launches.
    @State private var columns = TableColumnCustomization<BuildVsSellItem>()
    @AppStorage("buildVsSell.columns") private var savedColumns = Data()

    private var effectiveMaterialHub: String { materialHub.isEmpty ? defaultMaterialHub : materialHub }

    private var groupsForCategory: [BlueprintGroup] {
        categories.first { $0.name == category }?.groups ?? []
    }

    private struct LoadKey: Hashable {
        var category: String
        var group: String
        var search: String
        var sellHub: String
        var materialHub: String
        var ownedOnly: Bool
        var defaultME: Int
        var systemId: Int
        var structure: String
        var rigME: Double
        var rigTE: Double
        var facilityTax: Double
        var priceBand: Int
        var lookbackDays: Int
        var batchRuns: Int
        var refresh: Int
        var autoRefresh: Int
    }

    private var loadKey: LoadKey {
        LoadKey(category: category, group: group, search: search.trimmingCharacters(in: .whitespaces),
                sellHub: sellHub, materialHub: effectiveMaterialHub, ownedOnly: ownedOnly,
                defaultME: defaultME, systemId: systemId, structure: structure,
                rigME: rigME, rigTE: rigTE, facilityTax: facilityTax,
                priceBand: priceBand, lookbackDays: lookbackDays, batchRuns: batchRuns,
                refresh: refreshCounter,
                autoRefresh: autoRefreshCounter)
    }

    private var rows: [BuildVsSellItem] {
        (result?.items ?? []).sorted(using: sortOrder)
    }

    var body: some View {
        page
            // Opened from a right-click menu elsewhere – show what was asked for.
            .task(id: appState.intent) { takeIntent() }
    }

    private func takeIntent() {
        guard case .buildVsSell(let name) = appState.intent else { return }
        appState.intent = nil
        ownedOnly = false
        category = ""
        group = ""
        search = name
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
                .zIndex(1)   // search suggestions draw over the table
            Divider()
            if let result {
                table(result)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Compare", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { refreshNow() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // keep the controls at the top
            } else {
                ProgressView("Checking prices…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(subtitle)
        .task {
            if categories.isEmpty {
                categories = (try? await appState.backend.blueprintCategories()) ?? []
            }
        }
        .task(id: loadKey) { await load() }
        .onAppear {
            if let saved = try? JSONDecoder().decode(TableColumnCustomization<BuildVsSellItem>.self, from: savedColumns) {
                columns = saved
            }
        }
        .onChange(of: columns) { _, newValue in
            if let data = try? JSONEncoder().encode(newValue) { savedColumns = data }
        }
        .onChange(of: rangeDays) { refreshCounter += 1 }
        .task {
            // Reload every 5 minutes while the page is open (the backend's price cache lasts 5 minutes).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                autoRefreshCounter += 1
            }
        }
    }

    private var subtitle: String {
        guard let result else { return "" }
        if result.total > result.items.count {
            return "\(result.items.count) of \(result.total.short) blueprints"
        }
        return "\(result.items.count) blueprints"
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SuggestingSearchField(prompt: "Search blueprints", text: $search) { text in
                    await appState.backend.suggestBuildable(text, category: category, group: group)
                }

                Picker("Category", selection: $category) {
                    Text("All").tag("")
                    if !categories.isEmpty { Divider() }
                    ForEach(categories) { item in
                        Text("\(item.name) (\(item.count))").tag(item.name)
                    }
                    if !categories.contains(where: { $0.name == category }) && !category.isEmpty {
                        Text(category).tag(category)
                    }
                }
                .frame(width: 230)
                .onChange(of: category) { _, _ in group = "" }

                Picker("Group", selection: $group) {
                    Text("All").tag("")
                    if !groupsForCategory.isEmpty { Divider() }
                    ForEach(groupsForCategory) { item in
                        Text("\(item.name) (\(item.count))").tag(item.name)
                    }
                    if !groupsForCategory.contains(where: { $0.name == group }) && !group.isEmpty {
                        Text(group).tag(group)
                    }
                }
                .frame(width: 260)
                .disabled(category.isEmpty)

                HStack(spacing: 4) {
                    Text("Runs")
                    TextField("Runs", value: $batchRuns, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .onSubmit { batchRuns = max(1, min(batchRuns, 100_000)) }
                    Stepper("Runs", value: $batchRuns, in: 1...100_000)
                        .labelsHidden()
                }
                .help("How many runs to work out. Every figure in the table is for this many runs, and prices are averaged over the orders it would take to buy the materials and sell the result.")

                Spacer()
            }

            HStack(spacing: 12) {
                Picker("Sell at", selection: $sellHub) {
                    Text("Best hub").tag("best")
                    Divider()
                    ForEach(TradeHub.allCases) { hub in
                        Text(hub.rawValue).tag(hub.rawValue)
                    }
                }
                .frame(width: 170)
                .help("Where you'd sell what you build. Best hub picks the highest wallet figure of all five.")

                Picker("Materials valued at", selection: Binding(
                    get: { effectiveMaterialHub },
                    set: { materialHub = $0 }
                )) {
                    ForEach(TradeHub.allCases) { hub in
                        Text(hub.rawValue).tag(hub.rawValue)
                    }
                }
                .frame(width: 230)
                .help("Hub whose buy orders decide what the materials would sell for")

                Picker("ME if not owned", selection: $defaultME) {
                    ForEach(0...10, id: \.self) { me in
                        Text("ME \(me)").tag(me)
                    }
                }
                .frame(width: 190)
                .help("Material Efficiency to assume for T1 blueprints you don't own. T2 assumes an invented copy (ME 2).")

                Toggle("Only My Blueprints", isOn: $ownedOnly)

                PriceCheckMenu()
                PageKeyButton(columns: Self.columnKey)

                Spacer()

                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let asOf = result?.pricesAsOf {
                    Text("Prices as of \(Date(timeIntervalSince1970: asOf).formatted(date: .omitted, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Order books are fetched from ESI and kept for 5 minutes. The page reloads itself every 5 minutes; Refresh Prices fetches brand-new ones now.")
                }
                Button("Refresh Prices") { refreshNow() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Table

    private func table(_ result: BuildVsSellResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ISK for \(result.batchRuns ?? batchRuns) run(s). Verdict = sale − job fee − materials if sold (\(result.materialHub) buy orders, after \(result.salesTax.percent) tax), as a share of the materials. Prices checked against the \(result.lookbackDays ?? lookbackDays)-day median.")
                if result.total > result.items.count {
                    Text("Showing the first \(result.items.count) of \(result.total.short) A–Z – pick a group or search to narrow it.")
                        .foregroundStyle(.orange)
                }
                if let gaps = result.priceGaps, gaps > 0 {
                    Text("\(gaps) price(s) couldn't be fetched – EVE's servers timed out. Refresh Prices to try again.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
                TableColumn("Item", value: \.name) { item in
                    HStack(spacing: 6) {
                        let watched = isWatched(item)
                        Button {
                            toggleWatch(item)
                        } label: {
                            Image(systemName: watched ? "star.fill" : "star")
                                .foregroundStyle(watched ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(watched ? "Watched – competition is recorded. Click to stop." : "Watch: record how competition for this item changes over time")
                        AsyncImage(url: PublicESIClient.typeIconURL(typeID: item.productTypeId, size: 32)) { image in
                            image.resizable()
                        } placeholder: { Color.clear }
                        .frame(width: 18, height: 18)
                        Text(item.name).fontWeight(item.owned ? .semibold : .regular)
                        if item.unitsPerRun > 1 {
                            Text("×\(item.unitsPerRun)").foregroundStyle(.secondary)
                        }
                    }
                    .help("\(item.group) · \(item.tech)\n\n\(item.materialList)")
                }
                .width(min: 120, ideal: 170)
                .customizationID("item")

                TableColumn("Blueprint", value: \.ownedSort) { item in
                    Text(item.blueprintLabel)
                        .foregroundStyle(item.owned ? Color.primary : Color.secondary)
                }
                .width(min: 80, ideal: 100)
                .customizationID("blueprint")

                TableColumn("Materials", value: \.materialsIfSold) { item in
                    Text(item.materialsIfSold.compactISK).monospacedDigit()
                        .help("What the materials would put in your wallet if you sold them instead" + (item.materialFlagText.map { "\n\n" + $0 } ?? ""))
                        .foregroundStyle(item.unpricedMaterials > 0 || item.materialFlagText != nil ? Color.orange : Color.primary)
                }
                .width(min: 70, ideal: 85)
                .customizationID("materials")
                TableColumn("Sale", value: \.saleSort) { item in
                    if let sale = item.productSale, let hub = item.bestHub {
                        Text("\(sale.compactISK) · \(hub)").monospacedDigit()
                            .help(saleHelp(item, hub))
                    } else {
                        Text("No sell orders").foregroundStyle(.secondary)
                    }
                }
                .width(min: 110, ideal: 150)
                .customizationID("sale")

                TableColumn("Verdict", value: \.gainPercentSort) { item in
                    Text(item.verdictText).monospacedDigit().fontWeight(.semibold)
                        .foregroundStyle(item.verdict == .build ? Color.green : (item.verdict == .sell ? Color.red : Color.secondary))
                        .help(item.verdictHelp)
                }
                .width(min: 110, ideal: 140)
                .customizationID("verdict")

                TableColumn("Gain / Hour", value: \.gainPerHourMarketSort) { item in
                    HStack(spacing: 3) {
                        Text(item.gainPerHourMarket?.compactISK ?? "–").monospacedDigit()
                        if item.marketLimited == true {
                            Image(systemName: "cart").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .help(item.gainPerHourHelp)
                }
                .width(min: 80, ideal: 100)
                .customizationID("gainPerHourMarket")   // new ID so earlier saved layouts start with it hidden
                .defaultVisibility(.hidden)
                TableColumn("Fair Price", value: \.fairPriceSort) { item in
                    HStack(spacing: 4) {
                        if let fair = item.fairPrice {
                            let flagged = item.priceStatus == "inflated" || item.priceStatus == "dumped"
                            Text(fair.compactISK).monospacedDigit()
                                .foregroundStyle(flagged ? Color.orange : Color.primary)
                                .help(item.fairHelp(lookback: lookbackDays))
                        } else {
                            Text("No sales").foregroundStyle(.secondary)
                        }
                        PriceBadgesView(badges: item.priceBadges(lookback: lookbackDays, batchRuns: batchRuns).priceOnly)
                    }
                }
                .width(min: 110, ideal: 170)
                .customizationID("fairPrice")
                TableColumn("Listed · Sold/Day", value: \.soldPerDaySort) { item in
                    HStack(spacing: 4) {
                        Group {
                            Text(item.marketLabel).monospacedDigit().foregroundStyle(.secondary)
                            if let trend = item.trend, trend.sellersChange != 0 {
                                Text(trend.shortLabel)
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(trend.sellersChange > 0 ? Color.orange : Color.green)
                            }
                        }
                        .help(item.marketHelpWithHistory(range: HistoryRange.label(rangeDays)))
                        PriceBadgesView(badges: item.priceBadges(lookback: lookbackDays, batchRuns: batchRuns).marketOnly)
                    }
                }
                .width(min: 150, ideal: 250)
                .customizationID("market")
            }
            .contextMenu(forSelectionType: BuildVsSellItem.ID.self) { ids in
                if let id = ids.first, let item = rows.first(where: { $0.id == id }) {
                    ItemMenu(typeID: item.productTypeId, name: item.name)
                    MaterialsMenuContent(title: "Materials – \(result.batchRuns ?? batchRuns) run(s), ME \(item.me)",
                                         materials: item.materials)
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "Nothing Found",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(ownedOnly ? "None of your blueprints match." : "No blueprints match.")
                    )
                }
            }
        }
    }

    private func saleHelp(_ item: BuildVsSellItem, _ hub: String) -> String {
        var text = "Cheapest listing \(item.sellPrice?.isk ?? "–") in \(hub)."
        if let live = item.priceLive { text += "\nAverage over the cheapest orders for \(batchRuns) run(s): \(live.isk)." }
        if let used = item.priceUsed { text += "\nPrice used: \(used.isk) each, then broker fee and sales tax." }
        return text
    }

    /// The "?" key: what each column means.
    static let columnKey: [(String, String)] = [
        ("Item", "What you'd build. ★ = watch it (competition is recorded over time)."),
        ("Blueprint", "Your best copy (BPO/BPC and ME), or the ME assumed if you don't own one."),
        ("Materials", "What the materials would put in your wallet if you sold them instead of building."),
        ("Runs", "Everything in the table is for this many runs – type any number, e.g. 600 to see what a big competitor's batch looks like."),
        ("Sale", "What the batch sells for at the hub, after broker fee and sales tax."),
        ("Verdict", "Build or Sell mats, and by how much (gain compared with the materials' value). Either = within ±5%, too close to call. Hover for the ISK and per-hour figures."),
        ("Gain / Hour", "Hidden by default – right-click a column header to show it. Gain per hour, capped by your share of the market (🛒 = the market is the limit, not the factory)."),
        ("Fair Price", "Median of recent daily sales in the region – what the item really sells for."),
        ("Listed · Sold/Day", "Units listed for sale at the hub · units sold per day in the region."),
    ]

    // MARK: Watch

    private func isWatched(_ item: BuildVsSellItem) -> Bool {
        watchOverrides[item.productTypeId] ?? item.watched ?? false
    }

    private func toggleWatch(_ item: BuildVsSellItem) {
        let on = !isWatched(item)
        watchOverrides[item.productTypeId] = on
        Task {
            do {
                try await appState.backend.setWatch(typeID: item.productTypeId, on: on)
            } catch {
                watchOverrides[item.productTypeId] = !on
            }
        }
    }

    // MARK: Loading

    private func refreshNow() {
        forceFresh = true
        refreshCounter += 1
    }

    private func load() async {
        try? await Task.sleep(for: .milliseconds(450))   // let typing settle
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }

        let key = loadKey
        let fresh = forceFresh
        forceFresh = false
        var query: [URLQueryItem] = [
            URLQueryItem(name: "category", value: key.category),
            URLQueryItem(name: "group", value: key.group),
            URLQueryItem(name: "search", value: key.search),
            URLQueryItem(name: "owned_only", value: key.ownedOnly ? "true" : "false"),
            URLQueryItem(name: "sell_hub", value: key.sellHub),
            URLQueryItem(name: "material_hub", value: key.materialHub),
            URLQueryItem(name: "default_me", value: String(key.defaultME)),
            URLQueryItem(name: "structure", value: key.structure),
            URLQueryItem(name: "rig_me", value: String(key.rigME)),
            URLQueryItem(name: "rig_te", value: String(key.rigTE)),
            URLQueryItem(name: "facility_tax", value: String(key.facilityTax)),
            URLQueryItem(name: "fresh", value: fresh ? "true" : "false"),
            URLQueryItem(name: "price_band", value: String(key.priceBand)),
            URLQueryItem(name: "lookback_days", value: String(key.lookbackDays)),
            URLQueryItem(name: "batch_runs", value: String(max(1, key.batchRuns))),
            URLQueryItem(name: "batch_totals", value: "true"),
        ]
        if key.systemId > 0 {
            query.append(URLQueryItem(name: "system_id", value: String(key.systemId)))
        }
        do {
            let newResult = try await appState.backend.buildVsSell(query)
            guard !Task.isCancelled else { return }
            result = newResult
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private extension Double {
    /// iskShort without the " ISK" suffix, to keep the table narrow.
    var compactISK: String { iskShort.replacingOccurrences(of: " ISK", with: "") }
}
