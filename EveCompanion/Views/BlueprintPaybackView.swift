import SwiftUI

// MARK: - Models (/reference/blueprint-payback)

struct BlueprintPaybackResult: Decodable {
    let pricesAsOf: Double?
    let materialHub: String
    let sellHub: String
    let buyHub: String
    let salesTax: Double
    let total: Int
    let limit: Int
    let items: [PaybackItem]
    let lookbackDays: Int?
    /// Order books EVE's servers wouldn't give us this time (timeouts).
    let priceGaps: Int?
}

struct PaybackItem: Decodable, Identifiable {
    let blueprintTypeId: Int
    let productTypeId: Int
    let name: String
    let group: String
    let tech: String
    let unitsPerRun: Int
    let owned: Bool
    let me: Int
    let materialsIfSold: Double
    /// Materials for one run at the ME shown (from Build vs Sell).
    let materials: [MaterialNeed]?
    let jobFee: Double
    let buildSeconds: Double
    let bestHub: String?
    let sellPrice: Double?
    let productSale: Double?
    let gain: Double?
    let gainPerHour: Double?
    let soldPerDay: Double?
    let blueprintPrice: Double?
    let blueprintPriceSource: String?
    let notForSale: String?
    let paybackRuns: Int?
    let paybackSeconds: Double?
    let paybackMarketDays: Double?
    // Fair-price checks (FairPrice.swift): the blueprint's own price and the product's sale price.
    let blueprintCheck: PriceCheck?
    let priceLive: Double?
    let fairPrice: Double?
    let priceStatus: String?
    let priceTrend: String?
    let thinMarket: Bool?
    let daysToSell: Double?
    let spread: String?
    let saleCheck: PriceCheck?
    /// For runs that lose money: the sale price each unit would need to break even, and how far off it is.
    let breakEvenPrice: Double?
    let priceGap: Double?
    let currentPrice: Double?

    var breakEvenHelp: String {
        var text = "Never pays back: each run is \(abs(gain ?? 0).iskShort) worse than just selling the materials."
        if let breakEvenPrice, let currentPrice, let priceGap {
            text += "\nIt would need to sell for \(breakEvenPrice.iskShort) each – \(priceGap.iskShort) more than today's \(currentPrice.iskShort)."
        }
        if let check = saleCheck, let week = check.median7, let lookback = check.medianLookback,
           let change = check.priceChangePercent {
            let direction = change > 0.02 ? "up" : (change < -0.02 ? "down" : "flat")
            text += "\nPrice lately: \(week.iskShort) over 7 days vs \(lookback.iskShort) over the longer period (\(direction) \(abs(change).percent))."
        }
        return text
    }

    var id: Int { blueprintTypeId }


    // Sort keys – nothing to compare → bottom.
    var priceSort: Double { blueprintPrice ?? .greatestFiniteMagnitude }
    var gainSort: Double { gain ?? -.greatestFiniteMagnitude }
    var gainPerHourSort: Double { gainPerHour ?? -.greatestFiniteMagnitude }
    /// Pays back soonest first, then the ones that never do (smallest loss first), then nothing to compare.
    var runsSort: Int {
        guard let runs = paybackRuns else { return .max }
        return runs >= 0 ? runs : 1_000_000_000 - runs
    }
    var secondsSort: Double { paybackSeconds ?? .greatestFiniteMagnitude }
    var marketDaysSort: Double { paybackMarketDays ?? .greatestFiniteMagnitude }
    var soldPerDaySort: Double { soldPerDay ?? -1 }

    var whyNoPayback: String {
        if let notForSale { return notForSale }
        if gain == nil { return "Nothing for sale to compare" }
        if (gain ?? 0) <= 0 { return "Loses money" }
        return "–"
    }
}

// MARK: - View

/// Reference: if I buy this blueprint, how many runs (and how long) before it pays for itself?
struct BlueprintPaybackView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(BuildSettingsKey.systemId) private var systemId = BuildSettingsKey.defaultSystemId
    @AppStorage(BuildSettingsKey.structure) private var structure = StructureKind.npc.rawValue
    @AppStorage(BuildSettingsKey.rigME) private var rigME = 0.0
    @AppStorage(BuildSettingsKey.rigTE) private var rigTE = 0.0
    @AppStorage(BuildSettingsKey.facilityTax) private var facilityTax = 0.25
    @AppStorage(BuildSettingsKey.materialHub) private var defaultMaterialHub = BuildSettingsKey.defaultHub

    @AppStorage("payback.category") private var category = "Ship"
    @AppStorage("payback.group") private var group = "Frigate"
    @AppStorage("payback.sellHub") private var sellHub = "best"
    @AppStorage("payback.buyHub") private var buyHub = TradeHub.Jita.rawValue
    @AppStorage("payback.assumeME") private var assumeME = 0
    @AppStorage("payback.hideOwned") private var hideOwned = true
    @AppStorage(PriceCheckKey.band) private var priceBand = 50
    @AppStorage(PriceCheckKey.lookbackDays) private var lookbackDays = 30
    @AppStorage(PriceCheckKey.batchRuns) private var batchRuns = 10

    @State private var search = ""
    @State private var categories: [BlueprintCategory] = []
    @State private var result: BlueprintPaybackResult?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var refreshCounter = 0
    @State private var forceFresh = false
    @State private var selection: PaybackItem.ID?
    @State private var sortOrder = [KeyPathComparator(\PaybackItem.runsSort)]

    private var groupsForCategory: [BlueprintGroup] {
        categories.first { $0.name == category }?.groups ?? []
    }

    private struct LoadKey: Hashable {
        var category, group, search, sellHub, buyHub, materialHub, structure: String
        var assumeME, systemId, refresh: Int
        var hideOwned: Bool
        var rigME, rigTE, facilityTax: Double
        var priceBand = 50, lookbackDays = 30, batchRuns = 10
    }

    private var loadKey: LoadKey {
        LoadKey(category: category, group: group, search: search.trimmingCharacters(in: .whitespaces),
                sellHub: sellHub, buyHub: buyHub, materialHub: defaultMaterialHub, structure: structure,
                assumeME: assumeME, systemId: systemId, refresh: refreshCounter, hideOwned: hideOwned,
                rigME: rigME, rigTE: rigTE, facilityTax: facilityTax,
                priceBand: priceBand, lookbackDays: lookbackDays, batchRuns: batchRuns)
    }

    private var rows: [PaybackItem] {
        (result?.items ?? []).sorted(using: sortOrder)
    }

    var body: some View {
        page
            // Opened from a right-click menu elsewhere – show what was asked for.
            .task(id: appState.intent) { takeIntent() }
    }

    private func takeIntent() {
        guard case .payback(let name) = appState.intent else { return }
        appState.intent = nil
        hideOwned = false
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
                    Label("Couldn't Work It Out", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { refreshNow() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // keep the controls at the top
            } else {
                ProgressView("Checking blueprint and market prices…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(result.map { "\($0.items.count) blueprints · bought at \($0.buyHub)" } ?? "")
        .task {
            if categories.isEmpty {
                categories = (try? await appState.backend.blueprintCategories()) ?? []
            }
        }
        .task(id: loadKey) { await load() }
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

                Spacer()
            }

            HStack(spacing: 12) {
                Picker("Buy blueprint at", selection: $buyHub) {
                    ForEach(TradeHub.allCases) { hub in
                        Text(hub.rawValue).tag(hub.rawValue)
                    }
                }
                .frame(width: 210)
                .help("Hub whose sell orders decide what the blueprint costs")

                Picker("Sell at", selection: $sellHub) {
                    Text("Best hub").tag("best")
                    Divider()
                    ForEach(TradeHub.allCases) { hub in
                        Text(hub.rawValue).tag(hub.rawValue)
                    }
                }
                .frame(width: 170)

                Picker("Assume", selection: $assumeME) {
                    ForEach(0...10, id: \.self) { me in
                        Text("ME \(me)").tag(me)
                    }
                }
                .frame(width: 150)
                .help("A freshly bought blueprint is ME 0. Pick a higher ME to see payback after you've researched it.")

                Toggle("Hide ones I own", isOn: $hideOwned)

                PriceCheckMenu()
                PageKeyButton(columns: Self.columnKey)

                Spacer()

                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let asOf = result?.pricesAsOf {
                    Text("Prices as of \(Date(timeIntervalSince1970: asOf).formatted(date: .omitted, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Refresh Prices") { refreshNow() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Table

    /// The "?" key: what each column means.
    static let columnKey: [(String, String)] = [
        ("Item", "What the blueprint builds."),
        ("Blueprint Price", "Cheapest listing of the blueprint at the buy hub (orange = CCP's base price, as none are listed)."),
        ("Gain / Run", "Sale − job fee − materials if sold, per run – the same as Build vs Sell."),
        ("Runs to Pay Back", "Blueprint price ÷ gain per run. Green = 20 or fewer, orange = over 100. Never +x = each run loses against selling the materials; x is how much more each unit would have to sell for to break even. The arrow shows which way the price has moved (last 7 days vs the longer period)."),
        ("Build Time", "How long those pay-back runs take in one manufacturing slot."),
        ("Market Days", "How long the region's buyers take to absorb the pay-back units."),
        ("Gain / Hour", "Gain per run divided by the build time."),
        ("Sold / Day", "Units sold per day in the region."),
    ]

    private func table(_ result: BlueprintPaybackResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Gain per run = sale − job fee − materials if sold (\(result.materialHub) buy orders), same as Build vs Sell. Pay back = blueprint price ÷ gain per run.")
                if result.total > result.items.count {
                    Text("Showing the first \(result.items.count) of \(result.total.short) – pick a group or search to narrow it.")
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

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Item", value: \.name) { item in
                    HStack(spacing: 6) {
                        AsyncImage(url: PublicESIClient.typeIconURL(typeID: item.productTypeId, size: 32)) { image in
                            image.resizable()
                        } placeholder: { Color.clear }
                        .frame(width: 18, height: 18)
                        Text(item.name).fontWeight(item.owned ? .semibold : .regular)
                        if item.unitsPerRun > 1 {
                            Text("×\(item.unitsPerRun)").foregroundStyle(.secondary)
                        }
                    }
                    .help("\(item.group) · \(item.tech) · ME \(item.me)")
                }
                .width(min: 120, ideal: 160)

                TableColumn("Blueprint Price", value: \.priceSort) { item in
                    if let price = item.blueprintPrice {
                        HStack(spacing: 4) {
                            Text(price.iskShort).monospacedDigit()
                                .foregroundStyle((item.blueprintPriceSource ?? "").hasPrefix("CCP") ? Color.orange : Color.primary)
                                .help(item.blueprintPriceSource ?? "")
                            PriceBadgesView(badges: PriceBadge.badges(
                                item.blueprintCheck, place: result.buyHub, lookback: result.lookbackDays ?? lookbackDays,
                                what: "One blueprint", buying: true))
                        }
                    } else {
                        Text(item.notForSale ?? "–").foregroundStyle(.secondary)
                    }
                }
                .width(min: 100, ideal: 170)

                TableColumn("Gain / Run", value: \.gainSort) { item in
                    if let gain = item.gain {
                        HStack(spacing: 4) {
                            Text(gain.iskShort).monospacedDigit()
                                .foregroundStyle(gain >= 0 ? Color.green : Color.red)
                                .help("Sale \(item.productSale?.iskShort ?? "–") at \(item.bestHub ?? "–") − job fee \(item.jobFee.iskShort) − materials if sold \(item.materialsIfSold.iskShort)")
                            PriceBadgesView(badges: PriceBadge.badges(
                                item.saleCheck, place: item.bestHub ?? "the hub", lookback: result.lookbackDays ?? lookbackDays,
                                what: "Selling \(batchRuns) run(s)", spread: item.spread).priceOnly)
                        }
                    } else {
                        Text("–").foregroundStyle(.secondary)
                    }
                }
                .width(min: 100, ideal: 170)

                TableColumn("Runs to Pay Back", value: \.runsSort) { item in
                    if let runs = item.paybackRuns, runs < 0 {
                        HStack(spacing: 4) {
                            Text("Never").foregroundStyle(.secondary)
                            if let gap = item.priceGap {
                                Text("+\(gap.short)").monospacedDigit()
                            }
                            switch item.saleCheck?.priceDirection ?? "" {
                            case "up": Image(systemName: "arrow.up").foregroundStyle(.green)
                            case "down": Image(systemName: "arrow.down").foregroundStyle(.red)
                            case "flat": Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            default: EmptyView()
                            }
                        }
                        .help(item.breakEvenHelp)
                    } else if let runs = item.paybackRuns {
                        Text(runs.short).monospacedDigit().fontWeight(.semibold)
                            .foregroundStyle(runs <= 20 ? Color.green : (runs <= 100 ? Color.primary : Color.orange))
                    } else {
                        Text(item.whyNoPayback).foregroundStyle(.secondary)
                    }
                }
                .width(min: 90, ideal: 110)

                TableColumn("Build Time", value: \.secondsSort) { item in
                    Text(item.paybackSeconds?.durationLabel ?? "–").monospacedDigit()
                        .help("Time to build the pay-back runs in one manufacturing slot (\(item.buildSeconds.durationLabel) per run)")
                }

                TableColumn("Market Days", value: \.marketDaysSort) { item in
                    if let days = item.paybackMarketDays {
                        Text(days < 1 ? "< 1 day" : "\(Int(days.rounded())) days").monospacedDigit()
                            .foregroundStyle(days > 60 ? Color.orange : Color.secondary)
                            .help("How long the market takes to absorb the pay-back units at about \(String(format: "%.1f", item.soldPerDay ?? 0)) sold per day in the region")
                    } else {
                        Text("–").foregroundStyle(.secondary)
                    }
                }

                TableColumn("Gain / Hour", value: \.gainPerHourSort) { item in
                    Text(item.gainPerHour?.iskShort ?? "–").monospacedDigit()
                }

                TableColumn("Sold / Day", value: \.soldPerDaySort) { item in
                    HStack(spacing: 4) {
                        Text(item.soldPerDay.map { $0 >= 10 ? $0.short : String(format: "%.1f", $0) } ?? "–")
                            .monospacedDigit().foregroundStyle(.secondary)
                        PriceBadgesView(badges: PriceBadge.badges(
                            item.saleCheck, place: item.bestHub ?? "the hub", lookback: lookbackDays,
                            what: "Selling \(batchRuns) run(s)", spread: item.spread).marketOnly)
                    }
                }
                .width(min: 90, ideal: 170)
            }
            .contextMenu(forSelectionType: PaybackItem.ID.self) { ids in
                if let id = ids.first, let item = rows.first(where: { $0.id == id }) {
                    ItemMenu(typeID: item.productTypeId, name: item.name)
                    Button("Show the Blueprint in Market") { appState.showInMarket(item.blueprintTypeId) }
                    MaterialsMenuContent(title: "Materials – 1 run, ME \(item.me)", materials: item.materials ?? [])
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("Nothing Found", systemImage: "doc.text.magnifyingglass",
                                           description: Text("No blueprints match."))
                }
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
            URLQueryItem(name: "sell_hub", value: key.sellHub),
            URLQueryItem(name: "buy_hub", value: key.buyHub),
            URLQueryItem(name: "material_hub", value: key.materialHub),
            URLQueryItem(name: "assume_me", value: String(key.assumeME)),
            URLQueryItem(name: "hide_owned", value: key.hideOwned ? "true" : "false"),
            URLQueryItem(name: "structure", value: key.structure),
            URLQueryItem(name: "rig_me", value: String(key.rigME)),
            URLQueryItem(name: "rig_te", value: String(key.rigTE)),
            URLQueryItem(name: "facility_tax", value: String(key.facilityTax)),
            URLQueryItem(name: "fresh", value: fresh ? "true" : "false"),
        ]
        if key.systemId > 0 {
            query.append(URLQueryItem(name: "system_id", value: String(key.systemId)))
        }
        do {
            let newResult = try await appState.backend.blueprintPayback(query)
            guard !Task.isCancelled else { return }
            result = newResult
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
