import SwiftUI

/// Everything that changes a calculation – used to re-run it automatically.
private struct CalcKey: Hashable {
    var blueprintTypeId: Int?
    var runs: Int
    var me: Int
    var te: Int
    var systemId: Int
    var structure: String
    var rigME: Double
    var rigTE: Double
    var facilityTax: Double
    var materialHub: String
    var materialPrice: String
    var useOwned: Bool
    var stockLocationId: Int
    var refineryId: Int
    var useOre: Bool
    var oreYield: Double
    var oreYieldSkill: String
    var iceYield: Double
    var refineryTax: Double
    var priceBand: Int
    var lookbackDays: Int
    var refresh: Int
}

struct ManufacturingView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(BuildSettingsKey.systemId) private var systemId = BuildSettingsKey.defaultSystemId
    @AppStorage(BuildSettingsKey.structure) private var structure = StructureKind.npc.rawValue
    @AppStorage(BuildSettingsKey.rigME) private var rigME = 0.0
    @AppStorage(BuildSettingsKey.rigTE) private var rigTE = 0.0
    @AppStorage(BuildSettingsKey.facilityTax) private var facilityTax = 0.25
    @AppStorage(BuildSettingsKey.materialHub) private var materialHub = BuildSettingsKey.defaultHub
    @AppStorage(BuildSettingsKey.materialCostBasis) private var materialPrice = "sell"
    @AppStorage(BuildSettingsKey.useOwned) private var useOwned = true
    @AppStorage(BuildSettingsKey.stockLocationId) private var stockLocationId = 0
    @AppStorage(BuildSettingsKey.stockLocationName) private var stockLocationName = ""
    @AppStorage(BuildSettingsKey.refineryId) private var refineryId = 0
    @AppStorage(BuildSettingsKey.refineryName) private var refineryName = ""
    @AppStorage(BuildSettingsKey.useOre) private var useOre = true
    @AppStorage(BuildSettingsKey.oreYield) private var oreYield = BuildSettingsKey.defaultOreYield
    @AppStorage(BuildSettingsKey.oreYieldSkill) private var oreYieldSkill = BuildSettingsKey.defaultOreYieldSkill
    @AppStorage(BuildSettingsKey.iceYield) private var iceYield = BuildSettingsKey.defaultIceYield
    @AppStorage(BuildSettingsKey.refineryTax) private var refineryTax = BuildSettingsKey.defaultRefineryTax

    @State private var sdeStatus: SDEStatus?
    @State private var myProducts: [ProductOption] = []
    @State private var searchText = ""
    @State private var searchResults: [ProductOption] = []
    @State private var selectedID: Int?
    @State private var runs = 1
    @State private var me = 0
    @State private var te = 0
    @State private var result: CalcResult?
    @State private var isCalculating = false
    @State private var calcError: String?
    @State private var refreshCounter = 0
    @State private var showSettings = false
    @State private var trackRecord: TrackRecord?
    @AppStorage(HistoryRange.key) private var rangeDays = HistoryRange.defaultDays
    @AppStorage(PriceCheckKey.band) private var priceBand = 50
    @AppStorage(PriceCheckKey.lookbackDays) private var lookbackDays = 30

    private struct TrackKey: Hashable {
        var productID: Int?
        var rangeDays: Int
    }

    private var selectedProduct: ProductOption? {
        guard let selectedID else { return nil }
        return myProducts.first { $0.id == selectedID } ?? searchResults.first { $0.id == selectedID }
    }

    private var calcKey: CalcKey {
        CalcKey(blueprintTypeId: selectedID, runs: runs, me: me, te: te, systemId: systemId,
                structure: structure, rigME: rigME, rigTE: rigTE, facilityTax: facilityTax,
                materialHub: materialHub, materialPrice: materialPrice, useOwned: useOwned,
                stockLocationId: stockLocationId, refineryId: refineryId, useOre: useOre,
                oreYield: oreYield, oreYieldSkill: oreYieldSkill, iceYield: iceYield,
                refineryTax: refineryTax, priceBand: priceBand, lookbackDays: lookbackDays,
                refresh: refreshCounter)
    }

    var body: some View {
        page
            // Opened from a right-click menu elsewhere – show what was asked for.
            .task(id: appState.intent) { takeIntent() }
    }

    private func takeIntent() {
        guard case .manufacturing(let blueprintTypeID, let name) = appState.intent else { return }
        appState.intent = nil
        searchText = name
        selectedID = blueprintTypeID
    }

    private var page: some View {
        Group {
            if sdeStatus?.isReady == true {
                // Plain stack (not HSplitView): nested split views + the inspector can
                // trigger an AppKit layout-loop exception when their minimum widths don't fit.
                HStack(spacing: 0) {
                    productPicker
                        .frame(width: 250)
                    Divider()
                    resultPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                sdeWaitingView
            }
        }
        .inspector(isPresented: $showSettings) {
            BuildSettingsView()
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    refreshCounter += 1
                } label: {
                    Label("Recalculate", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Fetch fresh prices and recalculate")
                .disabled(selectedID == nil)

                Button {
                    showSettings.toggle()
                } label: {
                    Label("Build Settings", systemImage: "sidebar.right")
                }
                .help("Show or hide build settings")
            }
        }
        .task { await waitForStaticData() }
        .task(id: calcKey) { await calculate() }
        .task(id: TrackKey(productID: selectedProduct?.productTypeId, rangeDays: rangeDays)) { await loadTrackRecord() }
    }

    // MARK: - Product picker

    private var productPicker: some View {
        VStack(spacing: 0) {
            TextField("Search all items", text: $searchText, prompt: Text("Search anything buildable"))
                .textFieldStyle(.roundedBorder)
                .padding(8)

            List(selection: $selectedID) {
                if searchText.trimmingCharacters(in: .whitespaces).count >= 2 {
                    Section("Search Results") {
                        if searchResults.isEmpty {
                            Text("No matches").foregroundStyle(.secondary)
                        }
                        ForEach(searchResults.filter { r in !myProducts.contains { $0.id == r.id } }) { product in
                            ProductRow(product: product)
                            .contextMenu { ItemMenu(typeID: product.productTypeId, name: product.productName) }
                        }
                    }
                }

                Section("My Blueprints") {
                    if myProducts.isEmpty {
                        Text("No manufacturing blueprints found").foregroundStyle(.secondary)
                    }
                    ForEach(filteredMine) { product in
                        ProductRow(product: product)
                            .contextMenu { ItemMenu(typeID: product.productTypeId, name: product.productName) }
                    }
                }
            }
        }
        .task(id: searchText) {
            let text = searchText.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else {
                searchResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searchResults = (try? await appState.backend.searchProducts(text)) ?? []
        }
        .onChange(of: selectedID) { _, _ in
            guard let product = selectedProduct else { return }
            me = product.me ?? 0
            te = product.te ?? 0
            runs = 1
        }
    }

    private var filteredMine: [ProductOption] {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return myProducts }
        return myProducts.filter { $0.productName.localizedCaseInsensitiveContains(text) }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultPane: some View {
        if let product = selectedProduct {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(product)
                    inputs(product)

                    if let calcError {
                        Label(calcError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }

                    if let result {
                        summary(result)
                        hubSection(result)
                        trackRecordSection(result)
                        materialsSection(result)
                        ForEach(result.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.callout)
                        }
                    } else if isCalculating {
                        ProgressView("Fetching prices from all trade hubs…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(20)
            }
            .overlay(alignment: .topTrailing) {
                if isCalculating && result != nil {
                    ProgressView().controlSize(.small).padding(12)
                }
            }
        } else {
            ContentUnavailableView(
                "Choose Something to Build",
                systemImage: "hammer",
                description: Text("Pick one of your blueprints on the left, or search for any item that can be manufactured.")
            )
        }
    }

    private func header(_ product: ProductOption) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: PublicESIClient.typeIconURL(typeID: product.productTypeId, size: 64)) { image in
                image.resizable()
            } placeholder: {
                Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(product.productName).font(.title2).bold()
                HStack(spacing: 8) {
                    if let group = product.groupName { Text(group) }
                    if product.isOwned {
                        Text("·")
                        Text(ownedLabel(product))
                    } else {
                        Text("·")
                        Text("You don't own this blueprint")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func ownedLabel(_ product: ProductOption) -> String {
        let kind = product.isCopy == true ? "Copy" : "Original"
        var text = "Your \(kind): ME \(product.me ?? 0) / TE \(product.te ?? 0)"
        if product.isCopy == true, let runs = product.runs { text += " · \(runs) runs" }
        if let count = product.count, count > 1 { text += " · \(count) owned" }
        return text
    }

    private func inputs(_ product: ProductOption) -> some View {
        HStack(spacing: 24) {
            HStack(spacing: 6) {
                Text("Runs")
                TextField("Runs", value: $runs, format: .number)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Stepper("Runs", value: $runs, in: 1...10_000).labelsHidden()
            }
            HStack(spacing: 6) {
                Text("ME")
                Text("\(me)").monospacedDigit().frame(width: 22, alignment: .trailing)
                Stepper("ME", value: $me, in: 0...10).labelsHidden()
            }
            HStack(spacing: 6) {
                Text("TE")
                Text("\(te)").monospacedDigit().frame(width: 22, alignment: .trailing)
                Stepper("TE", value: $te, in: 0...20, step: 2).labelsHidden()
            }
            Spacer()
        }
        .onChange(of: runs) { _, newValue in
            if newValue < 1 { runs = 1 }
        }
    }

    private func summary(_ result: CalcResult) -> some View {
        let bestProfit = result.hubs.first { $0.hub == result.bestHub }?.sellOrder?.profitCash
        return HStack(alignment: .top, spacing: 12) {
            SummaryTile(
                title: "Build Time",
                value: result.time.seconds.durationLabel,
                detail: "Industry \(result.time.industryLevel.roman) · Adv. Industry \(result.time.advancedIndustryLevel.roman)"
            )
            SummaryTile(
                title: "Job Fee",
                value: result.job.fee.iskShort,
                detail: "\(result.job.system?.name ?? "No system") · index \(result.job.costIndex.percent)"
            )
            SummaryTile(
                title: result.materialPrice == "sell" ? "Materials (to buy)" : "Materials (value)",
                value: result.materialCost.iskShort,
                detail: result.materialPrice == "sell"
                    ? "Cost to buy at \(result.materialHub)"
                    : "\(result.materialHub) buy orders"
            )
            SummaryTile(
                title: "Out of Pocket",
                value: result.totalCashCost.iskShort,
                detail: "Materials to buy + job fee"
            )
            SummaryTile(
                title: "Best Hub",
                value: result.bestHub ?? "–",
                detail: bestProfit.map { "\($0.iskShort) cash profit" } ?? "No sell orders anywhere",
                valueColor: (bestProfit ?? 0) >= 0 ? .green : .red
            )
        }
    }

    private func hubSection(_ result: CalcResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Selling \(result.productQuantity)× \(result.productName) at Each Trade Hub")
                    .font(.headline)
                Spacer()
                PriceCheckMenu(showBatch: false)
                PageKeyButton(columns: Self.columnKey)
            }

            Table(result.hubs) {
                TableColumn("Hub") { hub in
                    HStack(spacing: 4) {
                        if hub.hub == result.bestHub {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                        Text(hub.hub).fontWeight(hub.hub == result.bestHub ? .semibold : .regular)
                    }
                    .help(hub.stationName)
                }
                .width(min: 70, ideal: 80)

                TableColumn("Price Each") { hub in
                    HStack(spacing: 4) {
                        Text(hub.sellOrder?.unitPrice.iskShort ?? "none").monospacedDigit()
                            .help(priceHelp(hub, quantity: result.productQuantity))
                        PriceBadgesView(badges: PriceBadge.badges(
                            hub.sellCheck, place: hub.hub, lookback: hub.lookbackDays ?? lookbackDays,
                            what: "Selling \(result.productQuantity)", spread: hub.spread).priceOnly)
                    }
                }
                .width(min: 110, ideal: 170)
                TableColumn("Cash Profit (×\(result.productQuantity))") { hub in
                    ProfitText(value: hub.sellOrder?.profitCash)
                        .help("List a sell order at the lowest price, minus broker fee \(hub.brokerFee.percent), sales tax \(hub.salesTax.percent), the job fee and any materials you still have to buy. Materials you already own count as free.")
                }
                TableColumn("Profit Each") { hub in
                    ProfitText(value: hub.sellOrder.map { $0.profitCash / Double(max(result.productQuantity, 1)) })
                        .help("Total cash profit divided by the \(result.productQuantity) items built.")
                }
                TableColumn("Margin") { hub in
                    Text(hub.sellOrder?.cashMargin?.percent ?? "–").monospacedDigit()
                        .help("Cash profit as a share of the sale price.")
                }
                TableColumn("ISK / Hour") { hub in
                    Text(hub.sellOrder?.cashIskPerHour?.iskShort ?? "–").monospacedDigit()
                        .help("Cash profit divided by the build time.")
                }
                TableColumn("Competition") { hub in
                    HStack(spacing: 4) {
                        Group {
                            Text("\(hub.sellVolume.short) units")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            if let trend = hub.trend, trend.sellersChange != 0 {
                                Text(trend.shortLabel)
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(trend.sellersChange > 0 ? Color.orange : Color.green)
                            }
                        }
                        .help("Units already listed for sale at this hub (\(hub.sellOrders) sellers)." + (hub.trend.map { "\n" + $0.description } ?? ""))
                        PriceBadgesView(badges: PriceBadge.badges(
                            hub.sellCheck, place: hub.hub, lookback: hub.lookbackDays ?? lookbackDays,
                            what: "Selling \(result.productQuantity)", spread: hub.spread).marketOnly)
                    }
                }
                .width(min: 120, ideal: 200)
            }
            .contextMenu(forSelectionType: HubResult.ID.self) { ids in
                if let id = ids.first, let hub = result.hubs.first(where: { $0.id == id }), let place = TradeHub.place(hub.hub) {
                    PlaceMenu(locationID: place.station, name: hub.stationName, systemID: place.system, systemName: place.systemName)
                }
            }
            .frame(height: CGFloat(result.hubs.count) * 26 + 30)
            .scrollDisabled(true)
        }
    }

    /// The "?" key: what each column means.
    static let columnKey: [(String, String)] = [
        ("Hub", "Trade hub you'd sell at. ★ = the best cash profit."),
        ("Price Each", "Price each item would sell for there, after the price check."),
        ("Cash Profit", "Sale − broker fee − sales tax − job fee − materials you still have to buy. Materials you own count as free."),
        ("Profit Each", "Cash profit divided by the number of items built."),
        ("Margin", "Cash profit as a share of the sale price."),
        ("ISK / Hour", "Cash profit divided by the build time."),
        ("Competition", "Units already listed for sale at that hub."),
        ("Needed / In Stock", "Materials the job needs · what you already have where you build."),
        ("From Ore / To Buy", "What your ore at the refinery covers · what's left to buy."),
        ("Unit Price / Buy Cost", "Price of one unit at the material hub · cost of what's left to buy."),
    ]

    private func priceHelp(_ hub: HubResult, quantity: Int) -> String {
        var text = "Cheapest listing at \(hub.hub): \(hub.lowestSell?.isk ?? "none")."
        if let live = hub.sellCheck?.live, quantity > 1 {
            text += "\nAverage over the cheapest orders for \(quantity): \(live.isk)."
        }
        if let fair = hub.sellCheck?.fair { text += "\nFair price (median of daily sales): \(fair.isk)." }
        if let used = hub.sellOrder?.unitPrice { text += "\nPrice used: \(used.isk) each." }
        return text
    }

    private func materialsSection(_ result: CalcResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Materials").font(.headline)

            Table(result.materials) {
                TableColumn("Material") { material in
                    HStack(spacing: 6) {
                        AsyncImage(url: PublicESIClient.typeIconURL(typeID: material.typeId, size: 32)) { image in
                            image.resizable()
                        } placeholder: {
                            Color.clear
                        }
                        .frame(width: 18, height: 18)
                        Text(material.name)
                    }
                }
                .width(min: 110, ideal: 150)

                TableColumn("Needed") { material in
                    Text(material.required.short).monospacedDigit()
                }
                .width(min: 55, ideal: 75)
                TableColumn("In Stock") { material in
                    Text(material.owned.short)
                        .monospacedDigit()
                        .foregroundStyle(material.owned >= material.required ? .green : .primary)
                }
                .width(min: 55, ideal: 75)
                TableColumn("From Ore") { material in
                    Text((material.fromOre ?? 0).short)
                        .monospacedDigit()
                        .foregroundStyle((material.fromOre ?? 0) > 0 ? .primary : .secondary)
                        .help("Minerals your ore at the refinery would reprocess into")
                }
                .width(min: 55, ideal: 75)
                TableColumn("To Buy") { material in
                    Text(material.toBuy.short)
                        .monospacedDigit()
                        .foregroundStyle(material.toBuy > 0 ? .orange : .secondary)
                }
                .width(min: 55, ideal: 75)
                TableColumn("Unit Price") { material in
                    Text(material.unitPrice.isk)
                        .monospacedDigit()
                        .help(material.priceSource)
                }
                .width(min: 70, ideal: 95)
                TableColumn("Value") { material in
                    Text(material.totalValue.iskShort).monospacedDigit()
                }
                .width(min: 55, ideal: 75)
                TableColumn("Buy Cost") { material in
                    Text(material.buyCost.iskShort).monospacedDigit()
                }
                .width(min: 55, ideal: 75)
            }
            .contextMenu(forSelectionType: CalcMaterial.ID.self) { ids in
                if let id = ids.first, let material = result.materials.first(where: { $0.id == id }) {
                    ItemMenu(typeID: material.typeId, name: material.name, quantity: material.toBuy > 0 ? material.toBuy : material.required)
                }
            }
            .frame(height: CGFloat(result.materials.count) * 26 + 30)
            .scrollDisabled(true)
        }
    }

    private var stockCaption: String {
        guard useOwned else { return "Not counting materials you own (turned off in Build Settings)." }
        var text: String
        if stockLocationId > 0 {
            text = "In Stock = what you have at \(stockLocationName.isEmpty ? "your chosen station" : stockLocationName), including containers."
        } else {
            text = "In Stock = everything you own, everywhere. Pick your build station in Build Settings to count only that."
        }
        if useOre && refineryId > 0 {
            text += " From Ore = minerals your ore at \(refineryName.isEmpty ? "the refinery" : refineryName) would reprocess into."
        }
        return text
    }

    private func breakdown(_ result: CalcResult) -> some View {
        DisclosureGroup("How this was calculated") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Base build time"); Text(result.time.baseSeconds.durationLabel) }
                GridRow { Text("Time modifier (TE, skills, facility)"); Text(result.time.modifier.percent) }
                GridRow { Text("Estimated item value (for job fee)"); Text(result.job.estimatedItemValue.isk) }
                GridRow { Text("System cost index"); Text(result.job.costIndex.percent) }
                GridRow { Text("Facility tax"); Text(result.job.facilityTax.percent) }
                GridRow { Text("SCC surcharge"); Text(result.job.sccSurcharge.percent) }
                GridRow { Text("Total job fee rate"); Text(result.job.feeRate.percent) }
                GridRow { Text("Sales tax (Accounting \(result.accountingLevel.roman))"); Text(result.hubs.first?.salesTax.percent ?? "–") }
            }
            .font(.callout)
            .monospacedDigit()
            .padding(.top, 6)
        }
    }

    // MARK: - Static data

    private var sdeWaitingView: some View {
        ContentUnavailableView {
            Label("Preparing Game Data", systemImage: "arrow.down.circle")
        } description: {
            VStack(spacing: 8) {
                Text(sdeStatus?.message ?? "Checking CCP's static data…")
                Text("This happens once (a few minutes), then again only after game patches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if sdeStatus?.state != "error" {
                    ProgressView().controlSize(.small)
                }
            }
        } actions: {
            if sdeStatus?.state == "error" {
                Button("Try Again") {
                    Task { sdeStatus = try? await appState.backend.updateSDE(force: true) }
                }
            }
        }
    }

    private func waitForStaticData() async {
        var requestedDownload = false
        while !Task.isCancelled {
            if let status = try? await appState.backend.sdeStatus() {
                sdeStatus = status
                if status.isReady { break }
                if status.state == "missing" && !requestedDownload {
                    requestedDownload = true
                    _ = try? await appState.backend.updateSDE()
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        if sdeStatus?.isReady == true {
            myProducts = (try? await appState.backend.myProducts()) ?? []
        }
    }

    // MARK: - Track record (from your history)

    @ViewBuilder
    private func trackRecordSection(_ result: CalcResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Track Record · \(HistoryRange.label(rangeDays))").font(.headline)
                Spacer()
                if let record = trackRecord, record.untrackedSold > 0 {
                    Text("\(record.untrackedSold.short) sold that weren't built in the recorded history")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let record = trackRecord, record.builtUnits > 0 || record.soldUnits > 0 {
                HStack(alignment: .top, spacing: 12) {
                    SummaryTile(
                        title: "Built",
                        value: "\(record.builtUnits.short)",
                        detail: "\(record.jobs) job\(record.jobs == 1 ? "" : "s") · \(record.inStock.short) still in stock"
                    )
                    SummaryTile(
                        title: "Real Cost Each",
                        value: record.costPerUnit?.iskShort ?? "–",
                        detail: "Materials you bought + job fees + refinery tax"
                    )
                    SummaryTile(
                        title: "Sold For Each",
                        value: record.averageSalePrice?.iskShort ?? "–",
                        detail: "\(record.soldUnits.short) sold · fees \(record.feeRate.percent)"
                    )
                    SummaryTile(
                        title: "Actual Profit Each",
                        value: record.profitPerUnit?.iskShort ?? "–",
                        detail: estimateComparison(record, result),
                        valueColor: (record.profitPerUnit ?? 0) >= 0 ? .green : .red
                    )
                    SummaryTile(
                        title: "Total Profit",
                        value: record.profit.iskShort,
                        detail: "On \(record.soldUnits.short) sold",
                        valueColor: record.profit >= 0 ? .green : .red
                    )
                }
                Text("Ore, minerals and stock you already had count as free; bought materials at what you paid (average cost). Worked out from your purchases, jobs and sales – ESI doesn't say exactly which units a job used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(trackRecord == nil
                     ? "Reading your history…"
                     : "No builds or sales of \(result.productName) recorded in this range yet. History builds up each time you open the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func estimateComparison(_ record: TrackRecord, _ result: CalcResult) -> String {
        guard record.profitPerUnit != nil,
              let estimate = result.hubs.first(where: { $0.hub == result.bestHub })?.sellOrder?.profitCash else {
            return "Sales − fees − real cost"
        }
        let perUnit = estimate / Double(max(result.productQuantity, 1))
        return "Calculator now: \(perUnit.iskShort)"
    }

    private func loadTrackRecord() async {
        guard let product = selectedProduct else {
            trackRecord = nil
            return
        }
        trackRecord = nil
        trackRecord = try? await appState.backend.trackRecord(productTypeID: product.productTypeId)
    }

    // MARK: - Calculate

    private func calculate() async {
        guard let product = selectedProduct, sdeStatus?.isReady == true else {
            result = nil
            return
        }
        // Small debounce so typing a run count doesn't fire a request per keystroke.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        isCalculating = true
        defer { isCalculating = false }

        var query: [URLQueryItem] = [
            URLQueryItem(name: "blueprint_type_id", value: String(product.blueprintTypeId)),
            URLQueryItem(name: "runs", value: String(max(1, runs))),
            URLQueryItem(name: "me", value: String(me)),
            URLQueryItem(name: "te", value: String(te)),
            URLQueryItem(name: "structure", value: structure),
            URLQueryItem(name: "rig_me", value: String(rigME)),
            URLQueryItem(name: "rig_te", value: String(rigTE)),
            URLQueryItem(name: "facility_tax", value: String(facilityTax)),
            URLQueryItem(name: "material_hub", value: materialHub),
            URLQueryItem(name: "material_price", value: materialPrice),
            URLQueryItem(name: "use_owned", value: String(useOwned)),
        ]
        if systemId > 0 {
            query.append(URLQueryItem(name: "system_id", value: String(systemId)))
        }
        if useOwned && stockLocationId > 0 {
            query.append(URLQueryItem(name: "stock_location", value: String(stockLocationId)))
        }
        if useOwned && useOre && refineryId > 0 {
            query.append(URLQueryItem(name: "refinery_location", value: String(refineryId)))
            query.append(contentsOf: BuildSettingsKey.refineryQuery())
        }

        do {
            let newResult = try await appState.backend.calculate(query)
            guard !Task.isCancelled else { return }
            result = newResult
            calcError = nil
        } catch {
            guard !Task.isCancelled else { return }
            calcError = error.localizedDescription
        }
    }
}

// MARK: - Small views

private struct ProductRow: View {
    let product: ProductOption

    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: PublicESIClient.typeIconURL(typeID: product.productTypeId, size: 32)) { image in
                image.resizable()
            } placeholder: {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(product.productName).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        if product.isOwned {
            let kind = product.isCopy == true ? "BPC" : "BPO"
            return "\(kind) · ME \(product.me ?? 0) · TE \(product.te ?? 0)"
        }
        return product.groupName ?? ""
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let detail: String
    var valueColor: Color = .primary

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProfitText: View {
    let value: Double?

    var body: some View {
        if let value {
            Text(value.iskShort)
                .monospacedDigit()
                .foregroundStyle(value >= 0 ? .green : .red)
        } else {
            Text("–").foregroundStyle(.secondary)
        }
    }
}
