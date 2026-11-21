import SwiftUI

/// Mine / Sell › Reprocess or Sell: loot, salvage, old modules and ore – worth more as they are,
/// or reprocessed (and broken down again where the pieces reprocess too)? One hub per item.
struct ReprocessOrSellView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(BuildSettingsKey.refineryId) private var refineryId = 0
    @AppStorage(BuildSettingsKey.refineryName) private var refineryName = ""
    @AppStorage(BuildSettingsKey.oreYield) private var oreYield = BuildSettingsKey.defaultOreYield
    @AppStorage(BuildSettingsKey.oreYieldSkill) private var oreYieldSkill = BuildSettingsKey.defaultOreYieldSkill
    @AppStorage(BuildSettingsKey.iceYield) private var iceYield = BuildSettingsKey.defaultIceYield
    @AppStorage(BuildSettingsKey.refineryTax) private var refineryTax = BuildSettingsKey.defaultRefineryTax
    @AppStorage(BuildSettingsKey.materialHub) private var materialHub = BuildSettingsKey.defaultHub

    /// "mine" (My Stuff) · "lookup" (Look Up)
    @AppStorage("reprocessOrSell.mode") private var mode = "mine"
    /// 0 = everywhere
    @AppStorage("reprocessOrSell.locationId") private var locationId = 0
    /// "here" · "refinery" · "compare"
    @AppStorage("reprocessOrSell.at") private var at = "here"
    /// "" = the material hub from Build Settings · "best" · a hub name
    @AppStorage("reprocessOrSell.sellHub") private var sellHubSetting = ""
    /// "buy" (sell to buy orders now) · "sell" (list and wait)
    @AppStorage("reprocessOrSell.price") private var price = "buy"
    @AppStorage("reprocessOrSell.lookupName") private var lookupName = ""
    @AppStorage("reprocessOrSell.lookupQuantity") private var lookupQuantity = 100
    @AppStorage(PriceCheckKey.band) private var priceBand = 50
    @AppStorage(PriceCheckKey.lookbackDays) private var lookbackDays = 30

    @State private var summary: ROSSummary?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var refreshCounter = 0
    @State private var locations: [StockLocation] = []
    @State private var filter = ""
    @State private var selectedRowID: ROSRow.ID?
    @State private var sortOrder = [KeyPathComparator(\ROSRow.gainSort, order: .reverse)]

    @State private var detail: ROSItem?
    @State private var detailError: String?
    @State private var detailLoading = false
    @State private var searchText = ""
    @State private var lookupRequest = 0

    private var sellHub: String { sellHubSetting.isEmpty ? materialHub : sellHubSetting }
    private var effectiveAt: String { refineryId == 0 ? "here" : at }

    private struct LoadKey: Hashable {
        var mode: String
        var refineryId: Int
        var oreYield: Double
        var oreYieldSkill: String
        var iceYield: Double
        var refineryTax: Double
        var locationId: Int
        var at: String
        var sellHub: String
        var price: String
        var priceBand: Int
        var lookbackDays: Int
        var refresh: Int
    }

    private var loadKey: LoadKey {
        LoadKey(mode: mode, refineryId: refineryId, oreYield: oreYield, oreYieldSkill: oreYieldSkill,
                iceYield: iceYield, refineryTax: refineryTax, locationId: locationId, at: effectiveAt,
                sellHub: sellHub, price: price, priceBand: priceBand, lookbackDays: lookbackDays,
                refresh: refreshCounter)
    }

    private struct DetailKey: Hashable {
        var load: LoadKey
        var row: String?
        var lookup: Int
    }

    private var detailKey: DetailKey {
        DetailKey(load: loadKey, row: mode == "mine" ? selectedRowID : nil, lookup: mode == "lookup" ? lookupRequest : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if mode == "lookup" {
                        lookupContent
                    } else {
                        mineContent
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationSubtitle(mode == "lookup" ? "Look Up" : "My Stuff")
        .toolbar {
            ToolbarItemGroup {
                if isLoading || detailLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    refreshCounter += 1
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Re-read your assets and prices")
            }
        }
        .task { await loadLocations() }
        .task(id: loadKey) { await load() }
        .task(id: detailKey) { await loadDetail() }
        .onChange(of: mode) { _, _ in detail = nil; detailError = nil }
    }

    // MARK: - Controls

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("", selection: $mode) {
                    Text("My Stuff").tag("mine")
                    Text("Look Up").tag("lookup")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)

                if mode == "mine" {
                    Picker("Where", selection: $locationId) {
                        Text("Everywhere").tag(0)
                        Divider()
                        ForEach(locations) { place in
                            Text(place.name).tag(place.locationId)
                        }
                        if locationId != 0 && !locations.contains(where: { $0.locationId == locationId }) {
                            Text("Chosen station").tag(locationId)
                        }
                    }
                    .frame(width: 260)
                    .help("Which station's items to check.")

                    TextField("Filter items", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                } else {
                    SuggestingSearchField(prompt: "Item to look up", text: $searchText, width: 260) { text in
                        await appState.backend.suggestReprocessable(text)
                    }
                    .onSubmit { startLookup() }
                    TextField("Qty", value: $lookupQuantity, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit { startLookup() }
                    Button("Check") { startLookup() }
                        .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Spacer()
                PriceCheckMenu(showBatch: false)
                PageKeyButton(columns: Self.columnKey)
            }

            HStack(spacing: 12) {
                Picker("Reprocess at", selection: Binding(get: { effectiveAt }, set: { at = $0 })) {
                    Text("Where it is").tag("here")
                    Text("My refinery").tag("refinery")
                    Text("Compare both").tag("compare")
                }
                .frame(width: 230)
                .disabled(refineryId == 0 || mode == "lookup")
                .help(refineryId == 0
                      ? "Set your refinery in Build Settings to reprocess there or compare."
                      : (mode == "lookup" ? "Look Up reprocesses at your refinery." : "Where the reprocessing happens. Compare picks whichever pays more for each item."))

                Picker("Sell at", selection: Binding(get: { sellHub }, set: { sellHubSetting = $0 })) {
                    Text("Best hub").tag("best")
                    Divider()
                    ForEach(TradeHub.allCases) { hub in
                        Text(hub.rawValue).tag(hub.rawValue)
                    }
                }
                .frame(width: 170)
                .help("Where you'd sell the item or what it breaks down into. Best hub picks, for each item, the one hub that pays most for the whole lot.")

                Picker("Prices", selection: $price) {
                    Text("Sell now (buy orders)").tag("buy")
                    Text("List and wait (sell orders)").tag("sell")
                }
                .frame(width: 260)
                .help("Sell now = what buyers pay today. List and wait = what sellers ask, less the broker fee – more money, but slower.")
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func startLookup() {
        let name = searchText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        lookupName = name
        lookupQuantity = max(1, min(lookupQuantity, 1_000_000_000))
        lookupRequest += 1
    }

    // MARK: - My Stuff

    @ViewBuilder
    private var mineContent: some View {
        if let summary {
            if summary.rows.isEmpty {
                ContentUnavailableView(
                    "Nothing to Reprocess Here",
                    systemImage: "arrow.3.trianglepath",
                    description: Text("None of your items here reprocess into anything (assets refresh every 10 minutes). Assembled ships are left out – repackage them to include them.")
                )
            } else {
                tiles(summary)
                itemTable(summary)
                if let row = summary.rows.first(where: { $0.id == selectedRowID }) {
                    detailSection(title: "\(row.quantity.short) \(row.name) at \(row.location)", summary: summary)
                } else {
                    Text("Click an item to see how it breaks down and what it's worth at all five hubs.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                notes(summary)
            }
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't Check Your Items", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { refreshCounter += 1 }
            }
        } else {
            ProgressView("Reading your items and fetching prices…")
                .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private func tiles(_ summary: ROSSummary) -> some View {
        let gain = summary.totalBest - summary.totalAsIs
        return HStack(alignment: .top, spacing: 12) {
            ROSTile(title: "Sell Everything as It Is", value: summary.totalAsIs.iskShort,
                    detail: "\(hubLabel(summary.sellHub)) · \(price == "sell" ? "listed" : "sold now"), after fees")
            ROSTile(title: "Doing the Best Thing With Each", value: summary.totalBest.iskShort,
                    detail: "\(summary.reprocessCount) to reprocess · \(summary.sellCount) to sell as they are")
            ROSTile(title: "Reprocessing the Winners Gains", value: gain.iskShort,
                    detail: gain > 0 ? "over selling everything as it is" : "nothing here is worth reprocessing",
                    color: gain > 0 ? .green : .secondary)
        }
    }

    private func hubLabel(_ hub: String) -> String { hub.lowercased() == "best" ? "Best hub" : hub }

    /// The "?" key: what each column means.
    static let columnKey: [(String, String)] = [
        ("Item", "Something you own that reprocesses into something. Assembled ships, what's fitted to them or in their cargo, and blueprints are left out."),
        ("Qty / Where", "How many, and the station or structure they're in."),
        ("As Is", "Cash from selling the stack as it is at the hub, after selling fees."),
        ("Reprocessed", "Cash from reprocessing it and doing the best thing with each piece – sell it, or reprocess it again – after reprocessing tax and selling fees."),
        ("Verdict", "Reprocess, Sell as is, or Either (within 5%). \"At refinery\" means it pays to take it to your refinery first."),
        ("Gain", "Reprocessed minus As Is, and that as a % of As Is."),
        ("Hub", "Where it's priced. With Best hub, the one hub that pays most for the item and everything it breaks down into."),
        ("Sold / Day", "How many of the item sell per day in the hub's region – low means it may take a while to sell as it is."),
    ]

    private func itemTable(_ summary: ROSSummary) -> some View {
        let text = filter.trimmingCharacters(in: .whitespaces)
        let rows = summary.rows
            .filter { text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) || ($0.groupName ?? "").localizedCaseInsensitiveContains(text) }
            .sorted(using: sortOrder)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Your Items").font(.headline)
            Table(rows, selection: $selectedRowID, sortOrder: $sortOrder) {
                TableColumn("Item", value: \.name) { row in
                    HStack(spacing: 6) {
                        AsyncImage(url: PublicESIClient.typeIconURL(typeID: row.typeId, size: 32)) { image in
                            image.resizable()
                        } placeholder: { Color.clear }
                        .frame(width: 18, height: 18)
                        Text(row.name)
                    }
                    .help(row.groupName ?? "")
                }
                .width(min: 150, ideal: 210)
                TableColumn("Qty", value: \.quantity) { row in
                    Text(row.quantity.short).monospacedDigit()
                }
                .width(min: 50, ideal: 60)
                TableColumn("Where", value: \.location) { row in
                    Text(row.location).lineLimit(1)
                        .help(whereHelp(row))
                }
                .width(min: 120, ideal: 200)
                TableColumn("As Is", value: \.asIsSort) { row in
                    HStack(spacing: 4) {
                        Text(row.asIs?.iskShort ?? "No buyers").monospacedDigit()
                            .foregroundStyle(asIsColor(row))
                        PriceBadgesView(badges: PriceBadge.badges(
                            row.check, place: row.hub, lookback: summary.lookbackDays ?? lookbackDays,
                            what: "Selling \(row.quantity.short)", sellSide: price == "sell"))
                    }
                }
                .width(min: 90, ideal: 130)
                TableColumn("Reprocessed", value: \.reprocessedSort) { row in
                    Text(reprocessedText(row)).monospacedDigit()
                        .foregroundStyle(reprocessedColor(row))
                        .help(reprocessedHelp(row, summary: summary))
                }
                .width(min: 90, ideal: 110)
                TableColumn("Verdict", value: \.verdictSort) { row in
                    verdictLabel(row)
                }
                .width(min: 110, ideal: 150)
                TableColumn("Gain", value: \.gainSort) { row in
                    if let gain = row.gain {
                        Text(gainText(gain, row.gainPercent)).monospacedDigit()
                            .foregroundStyle(gain > 0 ? Color.green : Color.secondary)
                    } else {
                        Text("–").foregroundStyle(.secondary)
                    }
                }
                .width(min: 80, ideal: 120)
                TableColumn("Hub", value: \.hub) { row in
                    Text(row.hub)
                }
                .width(min: 55, ideal: 70)
                TableColumn("Sold / Day", value: \.soldSort) { row in
                    Text(row.soldPerDay.map { $0.short } ?? "–").monospacedDigit()
                        .foregroundStyle((row.soldPerDay ?? 0) < Double(row.quantity) ? Color.orange : Color.primary)
                        .help((row.soldPerDay ?? 0) < Double(row.quantity)
                              ? "Fewer sell per day than you have – selling it as it is may take a while."
                              : "Sold per day in the \(row.hub) region.")
                }
                .width(min: 60, ideal: 80)
            }
            .contextMenu(forSelectionType: ROSRow.ID.self) { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    ItemMenu(typeID: row.typeId, name: row.name, quantity: row.quantity)
                    Divider()
                    PlaceMenu(locationID: row.locationId, name: row.location)
                }
            }
            .frame(height: CGFloat(rows.count) * 26 + 30)
            .scrollDisabled(true)
        }
    }

    private func asIsColor(_ row: ROSRow) -> Color {
        if row.asIs == nil { return .secondary }
        return row.verdict == "sell" ? .green : .primary
    }

    private func reprocessedColor(_ row: ROSRow) -> Color {
        if row.reprocessed == nil { return .secondary }
        if row.place.estimated { return .orange }
        return row.verdict == "reprocess" ? .green : .primary
    }

    private func haulHelp(_ row: ROSRow) -> String {
        guard row.needsHaul else { return "" }
        var text = "Pays more reprocessed at your refinery: \(row.volumeM3.short) m³ to move"
        if let jumps = row.jumpsToRefinery { text += ", \(jumps) jumps" }
        return text + "."
    }

    private func detailGain(_ item: ROSItem) -> String {
        guard let reprocessed = item.reprocessed else { return "–" }
        let asIs = item.asIs ?? 0
        let gain = reprocessed - asIs
        return gainText(gain, asIs > 0 ? gain / asIs : nil)
    }

    private func verdictColor(_ verdict: String) -> Color {
        switch verdict {
        case "reprocess": .green
        case "sell": .orange
        default: .secondary
        }
    }

    private func gainText(_ gain: Double, _ percent: Double?) -> String {
        let sign = gain >= 0 ? "+" : "−"
        var text = sign + abs(gain).iskShort
        if let percent { text += " (\(sign)\(abs(percent).percent))" }
        return text
    }

    private func reprocessedText(_ row: ROSRow) -> String {
        if let value = row.reprocessed { return value.iskShort }
        switch row.tree.stop {
        case "too_small": return "Need \(row.tree.portionSize)"
        case "no_reprocessing": return "Can't here"
        default: return "–"
        }
    }

    private func whereHelp(_ row: ROSRow) -> String {
        var text = row.location
        if row.volumeM3 > 0 { text += "\n\(row.volumeM3.short) m³" }
        if let jumps = row.jumpsToRefinery, jumps > 0 { text += " · \(jumps) jumps to your refinery" }
        return text
    }

    private func reprocessedHelp(_ row: ROSRow, summary: ROSSummary) -> String {
        var lines: [String] = []
        if row.tree.stop == "no_reprocessing" { lines.append("This station has no reprocessing plant.") }
        if row.tree.stop == "too_small" { lines.append("Reprocessing works in lots of \(row.tree.portionSize) – this stack is smaller.") }
        if let rate = row.tree.yieldRate { lines.append("Yield \(rate.percent) at \(row.place.name)") }
        if row.tree.tax > 0 { lines.append("Reprocessing tax \(row.tree.tax.iskShort)") }
        if row.place.estimated { lines.append("Someone else's structure: its yield and tax can't be read, so 50% and your refinery's tax are assumed.") }
        if summary.at == "compare" {
            if let here = row.reprocessedHere { lines.append("Where it is: \(here.iskShort)") }
            if let refinery = row.reprocessedRefinery { lines.append("At your refinery: \(refinery.iskShort)") }
        }
        lines.append("After reprocessing tax and selling fees; each piece is sold or reprocessed again, whichever pays more.")
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func verdictLabel(_ row: ROSRow) -> some View {
        switch row.verdict {
        case "reprocess":
            Label(row.needsHaul ? "Reprocess at refinery" : "Reprocess", systemImage: "arrow.3.trianglepath")
                .foregroundStyle(.green)
                .help(haulHelp(row))
        case "sell":
            Label("Sell as is", systemImage: "cart").foregroundStyle(.orange)
        case "either":
            Label("Either", systemImage: "equal.circle").foregroundStyle(.secondary)
                .help("Within 5% either way.")
        default:
            Text("No buyers").foregroundStyle(.secondary)
                .help("No one buys it or what it breaks down into at the hub.")
        }
    }

    private func notes(_ summary: ROSSummary) -> some View {
        DisclosureGroup("How it's worked out") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Modules, salvage and other items reprocess at the station's equipment rate (50% almost everywhere) × your Scrapmetal Processing \(summary.scrapmetalLevel.roman) (+2% a level). Refinery rigs, implants and the ore skills don't help them. Ore and ice aren't on this page – they're on Ore Reprocessing.")
                Text("Packaged ships and empty containers are included like any other item.")
                Text("NPC stations charge a reprocessing tax that falls with your standing towards the station's owner (none at 6.67). Your refinery uses the tax from Build Settings.")
                Text("Every piece that comes out is sold or reprocessed again – whichever pays more – and each item is priced at one hub only.")
                if let ore = summary.skippedOre, ore > 0 {
                    Text("\(ore) stacks of ore and ice were left out – see Ore Reprocessing.")
                }
                if summary.skippedShips > 0 {
                    Text("\(summary.skippedShips) assembled ships (and whatever is fitted to them or in their cargo) were left out. Repackage a ship to include it.")
                }
                if summary.noRefinery {
                    Text("No refinery is set in Build Settings, so everything is reprocessed where it is.")
                        .foregroundStyle(.orange)
                }
                if summary.priceGaps > 0 {
                    Text("\(summary.priceGaps) price lookups failed – try Refresh in a moment.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
    }

    // MARK: - Look Up

    @ViewBuilder
    private var lookupContent: some View {
        if lookupRequest == 0 && detail == nil {
            ContentUnavailableView(
                "Look Up Any Item",
                systemImage: "magnifyingglass",
                description: Text("Type an item and how many, then Check. It's reprocessed at \(refineryId != 0 && !refineryName.isEmpty ? refineryName : "a standard NPC station") and priced at all five hubs.")
            )
        } else {
            detailSection(title: "\(lookupQuantity.short) \(lookupName)", summary: nil)
        }
    }

    // MARK: - Detail (selected row / looked-up item)

    @ViewBuilder
    private func detailSection(title: String, summary: ROSSummary?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if summary != nil {
                    Button("Close") { selectedRowID = nil }
                        .buttonStyle(.link)
                }
            }
            if let detail {
                detailBody(detail)
            } else if let detailError {
                Text(detailError).foregroundStyle(.orange)
            } else {
                ProgressView("Pricing it at all five hubs…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    @ViewBuilder
    private func detailBody(_ item: ROSItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ROSTile(title: "As It Is", value: item.asIs?.iskShort ?? "No buyers",
                    detail: "\(item.hub), after selling fees")
            ROSTile(title: "Reprocessed", value: item.reprocessed?.iskShort ?? "–",
                    detail: "at \(item.place.name)" + (item.place.estimated ? " (estimated)" : ""))
            ROSTile(title: verdictTitle(item.verdict), value: detailGain(item),
                    detail: "Scrapmetal Processing \(item.scrapmetalLevel.roman)",
                    color: verdictColor(item.verdict))
        }

        Text("All Five Hubs").font(.subheadline.weight(.semibold))
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                Text("Hub").foregroundStyle(.secondary)
                Text("As Is").foregroundStyle(.secondary)
                Text("Reprocessed").foregroundStyle(.secondary)
                Text("Verdict").foregroundStyle(.secondary)
            }
            .font(.caption)
            ForEach(item.hubs) { hub in
                GridRow {
                    Text(hub.hub).fontWeight(hub.hub == item.hub ? .semibold : .regular)
                    Text(hub.asIs?.iskShort ?? "No buyers").monospacedDigit()
                    Text(hub.reprocessed?.iskShort ?? "–").monospacedDigit()
                    Text(verdictTitle(hub.verdict))
                        .foregroundStyle(verdictColor(hub.verdict))
                }
            }
        }
        if let split = item.splitValue, item.reprocessed != nil, split > item.bestValue * 1.02 {
            Text("Selling the pieces at different hubs would bring about \(split.iskShort) (+\((split - item.bestValue).iskShort)) – but means hauling to more than one hub.")
                .font(.callout).foregroundStyle(.secondary)
        }

        Text("How It Breaks Down at \(item.hub)").font(.subheadline.weight(.semibold))
        Text("Each line: worth as it is · worth reprocessed. The bold figure is the better one, and that's what counts towards the line above it.")
            .font(.caption).foregroundStyle(.secondary)
        BreakdownNodeView(node: item.tree, depth: 0)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    private func verdictTitle(_ verdict: String) -> String {
        switch verdict {
        case "reprocess": "Reprocess"
        case "sell": "Sell as Is"
        case "either": "Either"
        default: "No Buyers"
        }
    }

    // MARK: - Loading

    private func loadLocations() async {
        if searchText.isEmpty { searchText = lookupName }
        if let list = try? await appState.backend.stockLocations() {
            locations = list
        }
    }

    private func baseQuery() -> [URLQueryItem] {
        var query = BuildSettingsKey.refineryQuery()
        query.append(URLQueryItem(name: "refinery_id", value: String(refineryId)))
        query.append(URLQueryItem(name: "at", value: effectiveAt))
        query.append(URLQueryItem(name: "sell_hub", value: sellHub))
        query.append(URLQueryItem(name: "price", value: price))
        return query
    }

    private func load() async {
        guard mode == "mine" else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        var query = baseQuery()
        query.append(URLQueryItem(name: "location_id", value: String(locationId)))
        do {
            let result = try await appState.backend.reprocessOrSell(query)
            guard !Task.isCancelled else { return }
            summary = result
            errorMessage = nil
            if let selectedRowID, !result.rows.contains(where: { $0.id == selectedRowID }) {
                self.selectedRowID = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadDetail() async {
        var query = baseQuery()
        if mode == "lookup" {
            guard lookupRequest > 0, !lookupName.isEmpty else { return }
            query.append(URLQueryItem(name: "name", value: lookupName))
            query.append(URLQueryItem(name: "quantity", value: String(max(lookupQuantity, 1))))
            query.append(URLQueryItem(name: "location_id", value: "0"))
        } else {
            guard let selectedRowID, let row = summary?.rows.first(where: { $0.id == selectedRowID }) else {
                detail = nil
                detailError = nil
                return
            }
            query.append(URLQueryItem(name: "type_id", value: String(row.typeId)))
            query.append(URLQueryItem(name: "quantity", value: String(row.quantity)))
            query.append(URLQueryItem(name: "location_id", value: String(row.locationId)))
        }
        let wanted = detailKey
        detail = nil
        detailError = nil
        detailLoading = true
        defer { detailLoading = false }
        do {
            let result = try await appState.backend.reprocessOrSellItem(query)
            guard !Task.isCancelled, wanted == detailKey else { return }
            detail = result
        } catch {
            guard !Task.isCancelled, wanted == detailKey else { return }
            detailError = error.localizedDescription
        }
    }
}

/// One line of the breakdown, with its outputs folded underneath.
private struct BreakdownNodeView: View {
    let node: ROSNode
    let depth: Int
    @State private var open: Bool

    init(node: ROSNode, depth: Int) {
        self.node = node
        self.depth = depth
        _open = State(initialValue: depth == 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(depth) * 18, height: 1)
                if node.outputs.isEmpty {
                    Color.clear.frame(width: 12, height: 1)
                } else {
                    Button {
                        open.toggle()
                    } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                }
                AsyncImage(url: PublicESIClient.typeIconURL(typeID: node.typeId, size: 32)) { image in
                    image.resizable()
                } placeholder: { Color.clear }
                .frame(width: 16, height: 16)
                Text("\(node.quantity.short) × \(node.name)")
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(node.asIs?.iskShort ?? "no buyers")
                    .monospacedDigit()
                    .fontWeight(node.choice == "sell" ? .semibold : .regular)
                    .foregroundStyle(node.asIs == nil ? Color.secondary : Color.primary)
                    .frame(width: 90, alignment: .trailing)
                    .help(node.unitPrice.map { "\($0.isk) each, after selling fees" } ?? "Nobody buys it at this hub.")
                Text(reprocessedText)
                    .monospacedDigit()
                    .fontWeight(node.choice == "reprocess" ? .semibold : .regular)
                    .foregroundStyle(node.reprocessed == nil ? Color.secondary : Color.primary)
                    .frame(width: 110, alignment: .trailing)
                    .help(reprocessedHelp)
                choiceIcon
                    .frame(width: 18)
            }
            .font(.callout)
            .contextMenu { ItemMenu(typeID: node.typeId, name: node.name, quantity: node.quantity) }

            if open {
                ForEach(node.outputs) { child in
                    BreakdownNodeView(node: child, depth: depth + 1)
                }
            }
        }
    }

    private var reprocessedText: String {
        if let value = node.reprocessed { return value.iskShort }
        switch node.stop {
        case "too_small": return "need \(node.portionSize)"
        case "no_reprocessing": return "can't here"
        default: return "–"
        }
    }

    private var reprocessedHelp: String {
        var lines: [String] = []
        if let rate = node.yieldRate { lines.append("Yield \(rate.percent)") }
        if node.tax > 0 { lines.append("Reprocessing tax \(node.tax.iskShort)") }
        if node.leftover > 0 { lines.append("\(node.leftover.short) left over (not a full lot of \(node.portionSize))") }
        if node.stop == "too_small" { lines.append("Reprocessing works in lots of \(node.portionSize).") }
        if node.stop == "depth" { lines.append("Not broken down any further.") }
        if node.reprocessed == nil && node.stop == nil { lines.append("Doesn't reprocess into anything.") }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var choiceIcon: some View {
        switch node.choice {
        case "reprocess":
            Image(systemName: "arrow.3.trianglepath").foregroundStyle(.green).help("Reprocess")
        case "sell":
            Image(systemName: "cart").foregroundStyle(.orange).help("Sell as it is")
        default:
            Image(systemName: "minus").foregroundStyle(.secondary).help("No buyers")
        }
    }
}

private struct ROSTile: View {
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
