import SwiftUI
import Charts

// MARK: - Models (/market/...)

struct MarketGroupRow: Decodable {
    let marketGroupId: Int
    let parentGroupId: Int?
    let name: String
    let hasTypes: Int?
}

struct MarketTypeRow: Decodable, Identifiable, Hashable {
    let typeId: Int
    let name: String
    let marketGroupId: Int?
    let groupName: String?
    var id: Int { typeId }
}

struct MarketOrderRow: Decodable, Identifiable {
    let orderId: Int
    let price: Double
    let volumeRemain: Int
    let volumeTotal: Int
    let minVolume: Int
    let range: String
    let location: String
    let locationId: Int?
    let systemId: Int?
    let system: String
    let region: String
    let security: Double?
    let issued: String?
    let duration: Int

    var id: Int { orderId }
    var securitySort: Double { security ?? -2 }

    /// Days until the order expires (issued + duration).
    var daysLeft: Int? {
        guard let issued, let date = ISO8601DateFormatter().date(from: issued) else { return nil }
        let expires = date.addingTimeInterval(Double(duration) * 86400)
        return max(0, Int(expires.timeIntervalSinceNow / 86400))
    }
    var daysLeftSort: Int { daysLeft ?? -1 }

    var rangeLabel: String {
        switch range {
        case "station": return "Station"
        case "solarsystem": return "System"
        case "region": return "Region"
        default: return "\(range) jumps"
        }
    }
}

struct MarketHistoryRow: Decodable, Identifiable {
    let date: String
    let average: Double
    let highest: Double
    let lowest: Double
    let volume: Int
    let orderCount: Int?

    var id: String { date }
    var day: Date {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        return parser.date(from: date) ?? .now
    }
}

struct HubCompareRow: Decodable, Identifiable {
    let hub: String
    let sell: Double?
    let buy: Double?
    let sellVolume: Int
    let buyVolume: Int
    let sellOrders: Int
    let buyOrders: Int
    var id: String { hub }
}

struct MarketItemDetail: Decodable {
    let typeId: Int
    let name: String
    let group: String?
    let category: String?
    let volume: Double
    let scope: String
    let referenceHub: String
    let sellOrders: [MarketOrderRow]
    let buyOrders: [MarketOrderRow]
    let sellOrderCount: Int
    let buyOrderCount: Int
    let sellUnits: Int
    let buyUnits: Int
    let history: [MarketHistoryRow]
    let hubs: [HubCompareRow]
    let check: PriceCheck?
    let spread: String?
    let soldPerDay: Double?
    let averagePrice: Double?
    let competitionTrend: CompetitionTrend?
    let lookbackDays: Int?

    var lowestSell: Double? { sellOrders.first?.price }
    var highestBuy: Double? { buyOrders.first?.price }
    var spreadPercent: Double? {
        guard let sell = lowestSell, let buy = highestBuy, sell > 0 else { return nil }
        return (sell - buy) / sell
    }
}

/// The market tree, built from the flat list of groups.
struct MarketTreeNode: Identifiable, Hashable {
    let id: Int
    let name: String
    let hasTypes: Bool
    var children: [MarketTreeNode]?

    static func build(_ rows: [MarketGroupRow]) -> [MarketTreeNode] {
        var byParent: [Int: [MarketGroupRow]] = [:]
        for row in rows { byParent[row.parentGroupId ?? 0, default: []].append(row) }
        func make(_ parent: Int, depth: Int) -> [MarketTreeNode] {
            guard depth < 12 else { return [] }
            return (byParent[parent] ?? []).sorted { $0.name < $1.name }.map { row in
                let kids = make(row.marketGroupId, depth: depth + 1)
                return MarketTreeNode(id: row.marketGroupId, name: row.name, hasTypes: (row.hasTypes ?? 0) == 1,
                                      children: kids.isEmpty ? nil : kids)
            }
        }
        return make(0, depth: 0)
    }
}

/// Search results and the watchlist, laid out in the same market groups and sub-groups as the
/// full tree – only the branches that lead to a matching item, opened by default.
struct MarketFilteredNode: Identifiable {
    let id: Int
    let name: String
    var children: [MarketFilteredNode]
    var items: [MarketTypeRow]

    static func build(items: [MarketTypeRow], groups: [MarketGroupRow]) -> (tree: [MarketFilteredNode], loose: [MarketTypeRow]) {
        let byID = Dictionary(groups.map { ($0.marketGroupId, $0) }, uniquingKeysWith: { a, _ in a })
        var itemsIn: [Int: [MarketTypeRow]] = [:]
        var childIDs: [Int: Set<Int>] = [:]
        var roots: Set<Int> = []
        var loose: [MarketTypeRow] = []
        for item in items {
            guard let gid = item.marketGroupId, byID[gid] != nil else { loose.append(item); continue }
            itemsIn[gid, default: []].append(item)
            // Walk up to the root, recording each link.
            var current = gid
            var guardDepth = 0
            while let parent = byID[current]?.parentGroupId, byID[parent] != nil, guardDepth < 12 {
                childIDs[parent, default: []].insert(current)
                current = parent
                guardDepth += 1
            }
            roots.insert(current)
        }
        func make(_ id: Int) -> MarketFilteredNode {
            let kids = (childIDs[id] ?? []).map(make).sorted { $0.name < $1.name }
            let mine = (itemsIn[id] ?? []).sorted { $0.name < $1.name }
            return MarketFilteredNode(id: id, name: byID[id]?.name ?? "?", children: kids, items: mine)
        }
        return (roots.map(make).sorted { $0.name < $1.name }, loose)
    }
}

// MARK: - View

/// Sell › Market: browse the market like in game while you wait for a mining run or a job.
struct MarketView: View {
    @State private var highlight = RowHighlights()
    @Environment(AppState.self) private var appState

    @AppStorage("market.scope") private var scope = BuildSettingsKey.defaultHub
    @AppStorage("market.typeId") private var selectedTypeID = 0
    @AppStorage("market.historyDays") private var historyDays = 90
    @AppStorage(BuildSettingsKey.materialHub) private var homeHub = BuildSettingsKey.defaultHub

    @State private var tree: [MarketTreeNode] = []
    @State private var groupRows: [MarketGroupRow] = []
    @State private var searchResults: [MarketTypeRow] = []
    @State private var watchedItems: [MarketTypeRow] = []
    /// Left column shows the market tree or your watchlist (search results replace either).
    @AppStorage("market.showWatchlist") private var showWatchlist = false
    @State private var search = ""
    @State private var detail: MarketItemDetail?
    @State private var detailError: String?
    @State private var loadingDetail = false
    @State private var watched: Set<Int> = []
    @State private var refreshCounter = 0
    @State private var sellSort = [KeyPathComparator(\MarketOrderRow.price)]
    @State private var buySort = [KeyPathComparator(\MarketOrderRow.price, order: .reverse)]

    var body: some View {
        HSplitView {
            browser
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
            detailPane
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await loadWatched()
            // The tree comes from the static data; while that's still being rebuilt, keep checking.
            while tree.isEmpty && !Task.isCancelled {
                groupRows = (try? await appState.backend.marketGroups()) ?? []
                tree = MarketTreeNode.build(groupRows)
                if tree.isEmpty { try? await Task.sleep(for: .seconds(10)) }
            }
        }
        .task(id: search) { await loadSearch() }
        .onChange(of: appState.watchedTypes) { _, now in
            // Right-click menus change the watchlist – follow them.
            watched = now
            Task { watchedItems = now.isEmpty ? [] : ((try? await appState.backend.marketNames(Array(now))) ?? []) }
        }
        .task(id: "\(selectedTypeID)|\(scope)|\(refreshCounter)") { await loadDetail() }
    }

    private var searching: Bool { search.trimmingCharacters(in: .whitespaces).count >= 2 }

    // MARK: Left: search, watched and the market tree – drill down to the items themselves

    private var selection: Binding<Int?> {
        Binding(get: { selectedTypeID == 0 ? nil : selectedTypeID }, set: { selectedTypeID = $0 ?? 0 })
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 8) {
            SuggestingSearchField(prompt: "Search the market", text: $search, width: 240) { text in
                ((try? await appState.backend.marketSearch(text)) ?? []).prefix(8).map(\.name)
            }
            .zIndex(1)
            .padding(.horizontal, 10)
            .padding(.top, 10)

            HStack(spacing: 6) {
                Button {
                    search = ""
                    showWatchlist = false
                } label: {
                    Label("Market", systemImage: "list.bullet.indent")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(!showWatchlist && !searching ? Color.accentColor : nil)

                Button {
                    search = ""
                    showWatchlist = true
                } label: {
                    Label("Watchlist (\(watched.count))", systemImage: "star.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(showWatchlist && !searching ? Color.accentColor : nil)
            }
            .padding(.horizontal, 10)

            List(selection: selection) {
                if searching {
                    Section("Search: \(search)") {
                        if searchResults.isEmpty {
                            Text("Nothing on the market matches.").font(.caption).foregroundStyle(.secondary)
                        }
                        filteredTree(searchResults)
                    }
                } else if showWatchlist {
                    Section("Watchlist") {
                        if watchedItems.isEmpty {
                            Text("Right-click any item (in the market tree or on its page) and choose Add to Watchlist.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        filteredTree(watchedItems)
                    }
                } else {
                    Section("Market") {
                        if tree.isEmpty {
                            Text("Loading the market tree – if the app is updating its static data, it appears in a minute or two.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(tree) { node in
                            MarketGroupBranch(node: node, watched: watched, onToggleWatch: toggleWatch) { group in
                                (try? await appState.backend.marketTypes(group: group)) ?? []
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// Items shown under their own market groups and sub-groups, like the full tree.
    @ViewBuilder
    private func filteredTree(_ items: [MarketTypeRow]) -> some View {
        let built = MarketFilteredNode.build(items: items, groups: groupRows)
        ForEach(built.tree) { node in
            MarketFilteredBranch(node: node, watched: watched, onToggleWatch: toggleWatch)
        }
        ForEach(built.loose) { item in itemRow(item, showGroup: true) }
    }

    private func itemRow(_ item: MarketTypeRow, showGroup: Bool) -> some View {
        MarketItemRow(item: item, showGroup: showGroup, watched: watched.contains(item.typeId),
                      onToggleWatch: toggleWatch)
            .tag(item.typeId)
    }

    // MARK: Right: the item

    @ViewBuilder
    private var detailPane: some View {
        if selectedTypeID == 0 {
            ContentUnavailableView("Browse the Market", systemImage: "chart.bar.doc.horizontal",
                                   description: Text("Pick a group in the tree, search, or open your watched items – then an item to see every order, its price history and how the five hubs compare."))
        } else if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(detail)
                    tiles(detail)
                    hubStrip(detail)
                    historyChart(detail)
                    orders(detail)
                }
                .padding(16)
            }
            .overlay(alignment: .topTrailing) {
                if loadingDetail { ProgressView().controlSize(.small).padding(8) }
            }
        } else if let detailError {
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(detailError)
            } actions: {
                Button("Try Again") { refreshCounter += 1 }
            }
        } else {
            ProgressView("Reading the market…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ d: MarketItemDetail) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AsyncImage(url: PublicESIClient.typeIconURL(typeID: d.typeId, size: 64)) { image in
                image.resizable()
            } placeholder: { Color.clear }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.name).font(.title2).bold().lineLimit(1).minimumScaleFactor(0.7)
                    Button {
                        toggleWatch(d.typeId)
                    } label: {
                        Image(systemName: watched.contains(d.typeId) ? "star.fill" : "star")
                            .foregroundStyle(watched.contains(d.typeId) ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Watch: keep it in the Watchlist and record how its competition changes (or right-click)")
                }
                Text([d.category, d.group].compactMap { $0 }.joined(separator: " › ") + " · \(d.volume.short) m³")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contextMenu { ItemMenu(typeID: d.typeId, name: d.name, hideMarket: true) }
            Spacer()
            Picker("Orders in", selection: $scope) {
                ForEach(TradeHub.allCases) { hub in Text("\(hub.rawValue)'s region").tag(hub.rawValue) }
                Divider()
                Text("The 5 hub stations").tag("hubs")
            }
            .frame(width: 240)
            Button("Refresh") { refreshCounter += 1 }
        }
    }

    private func tiles(_ d: MarketItemDetail) -> some View {
        let lookback = d.lookbackDays ?? 30
        let badges = PriceBadge.badges(d.check, place: d.referenceHub, lookback: lookback,
                                       what: "One unit", spread: d.spread)
        return HStack(alignment: .top, spacing: 10) {
            tile("Lowest Sell", d.lowestSell?.short ?? "–", "\(d.sellOrderCount) orders · \(d.sellUnits.short) units")
            tile("Highest Buy", d.highestBuy?.short ?? "–", "\(d.buyOrderCount) orders · \(d.buyUnits.short) units")
            tile("Spread", d.spreadPercent?.percent ?? "–", "between best sell and buy")
            VStack(alignment: .leading, spacing: 4) {
                Text("Fair Price · \(d.referenceHub)").font(.caption).foregroundStyle(.secondary)
                Text(d.check?.fair?.short ?? "–").font(.title2).bold().monospacedDigit()
                PriceBadgesView(badges: badges)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            tile("Sold / Day", d.soldPerDay.map { $0 >= 10 ? $0.short : String(format: "%.1f", $0) } ?? "–",
                 "\(lookback)-day average in the region")
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).bold().monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func hubStrip(_ d: MarketItemDetail) -> some View {
        let bestSell = d.hubs.compactMap(\.sell).min()
        let bestBuy = d.hubs.compactMap(\.buy).max()
        return VStack(alignment: .leading, spacing: 6) {
            Text("The Five Hubs").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("Hub").foregroundStyle(.secondary)
                    Text("Lowest Sell").foregroundStyle(.secondary)
                    Text("Listed").foregroundStyle(.secondary)
                    Text("Highest Buy").foregroundStyle(.secondary)
                    Text("Wanted").foregroundStyle(.secondary)
                }
                .font(.caption)
                ForEach(d.hubs) { hub in
                    GridRow {
                        Text(hub.hub).fontWeight(hub.hub == homeHub ? .semibold : .regular)
                        Text(hub.sell?.short ?? "–").monospacedDigit()
                            .foregroundStyle(hub.sell != nil && hub.sell == bestSell ? Color.green : Color.primary)
                        Text("\(hub.sellVolume.short) · \(hub.sellOrders) orders").monospacedDigit().foregroundStyle(.secondary)
                        Text(hub.buy?.short ?? "–").monospacedDigit()
                            .foregroundStyle(hub.buy != nil && hub.buy == bestBuy ? Color.green : Color.primary)
                        Text("\(hub.buyVolume.short) · \(hub.buyOrders) orders").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Text("Green = cheapest place to buy / best place to sell straight away.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func chartKey(_ color: Color, dashed: Bool, _ label: String) -> some View {
        HStack(spacing: 4) {
            Path { p in p.move(to: CGPoint(x: 0, y: 4)); p.addLine(to: CGPoint(x: 16, y: 4)) }
                .stroke(color, style: dashed ? ChartStyle.referenceLine : ChartStyle.line)
                .frame(width: 16, height: 8)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func historyChart(_ d: MarketItemDetail) -> some View {
        let cutoff = Date().addingTimeInterval(-Double(historyDays) * 86400)
        let rows = d.history.filter { $0.day >= cutoff }
        // Average for the period shown, weighted by units sold (falls back to a plain mean).
        let units = rows.reduce(0) { $0 + $1.volume }
        let periodAverage: Double? = rows.isEmpty ? nil
            : units > 0 ? rows.reduce(0.0) { $0 + $1.average * Double($1.volume) } / Double(units)
            : rows.reduce(0.0) { $0 + $1.average } / Double(rows.count)
        let fair: Double? = d.check?.fair
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Price History · \(d.referenceHub)'s region").font(.headline)
                Spacer()
                Picker("Show", selection: $historyDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }
            if rows.isEmpty {
                Text("No sales in this period.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(rows) { row in
                        AreaMark(x: .value("Day", row.day, unit: .day),
                                 yStart: .value("Low", row.lowest), yEnd: .value("High", row.highest))
                            .foregroundStyle(Color.accentColor.opacity(0.15))
                        LineMark(x: .value("Day", row.day, unit: .day), y: .value("Average", row.average))
                            .lineStyle(ChartStyle.line)
                            .foregroundStyle(Color.accentColor)
                    }
                    if let periodAverage {
                        RuleMark(y: .value("Period average", periodAverage))
                            .lineStyle(ChartStyle.referenceLine)
                            .foregroundStyle(Color.orange)
                    }
                    if let fair {
                        RuleMark(y: .value("Fair price", fair))
                            .lineStyle(ChartStyle.referenceLine)
                            .foregroundStyle(Color.green)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text(v.short) } }
                    }
                }
                .frame(height: 180)
                Chart(rows) { row in
                    BarMark(x: .value("Day", row.day, unit: .day), y: .value("Sold", row.volume))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Int.self) { Text(v.short) } }
                    }
                }
                .frame(height: 70)
                HStack(spacing: 14) {
                    chartKey(Color.accentColor, dashed: false, "Daily average")
                    if let periodAverage { chartKey(.orange, dashed: true, "Period average \(periodAverage.short)") }
                    if let fair { chartKey(.green, dashed: true, "Fair price \(fair.short)") }
                    Spacer()
                }
                .font(.caption2)
                Text("Band = daily low to high · bars = units sold per day. Period average is weighted by units sold; fair price is the app's price check.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func orders(_ d: MarketItemDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sellers · \(d.sellOrderCount) orders" + (d.sellOrderCount > d.sellOrders.count ? " (cheapest \(d.sellOrders.count) shown)" : ""))
                    .font(.headline)
                Table(d.sellOrders.sorted(using: sellSort), selection: highlight.row("t540"), sortOrder: $sellSort) {
                    TableColumn("Price", value: \.price) { o in
                        Text(o.price.short).monospacedDigit().help("Exact: \(o.price.iskExact)")
                    }
                    TableColumn("Quantity", value: \.volumeRemain) { Text($0.volumeRemain.short).monospacedDigit() }
                    TableColumn("Location", value: \.location) { Text($0.location).lineLimit(1) }
                        .width(min: 180, ideal: 320)
                    TableColumn("Security", value: \.securitySort) { o in
                        if let sec = o.security {
                            Text(securityLabel(sec)).monospacedDigit().foregroundStyle(securityColor(sec))
                        }
                    }
                    TableColumn("Expires", value: \.daysLeftSort) { Text($0.daysLeft.map { "\($0)d" } ?? "–").monospacedDigit() }
                }
                .contextMenu(forSelectionType: MarketOrderRow.ID.self) { ids in
                    if let id = ids.first, let order = (d.sellOrders + d.buyOrders).first(where: { $0.id == id }), let location = order.locationId {
                        PlaceMenu(locationID: location, name: order.location, systemID: order.systemId, systemName: order.system)
                    }
                }
                .frame(height: 240)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Buyers · \(d.buyOrderCount) orders" + (d.buyOrderCount > d.buyOrders.count ? " (best \(d.buyOrders.count) shown)" : ""))
                    .font(.headline)
                Table(d.buyOrders.sorted(using: buySort), selection: highlight.row("t564"), sortOrder: $buySort) {
                    TableColumn("Price", value: \.price) { o in
                        Text(o.price.short).monospacedDigit().help("Exact: \(o.price.iskExact)")
                    }
                    TableColumn("Quantity", value: \.volumeRemain) { Text($0.volumeRemain.short).monospacedDigit() }
                    TableColumn("Min. Volume", value: \.minVolume) { o in
                        Text(o.minVolume.short).monospacedDigit()
                            .foregroundStyle(o.minVolume > 1 ? Color.orange : Color.secondary)
                            .help(o.minVolume > 1 ? "Only buys \(o.minVolume) or more at a time" : "")
                    }
                    TableColumn("Range", value: \.range) { Text($0.rangeLabel) }
                    TableColumn("Location", value: \.location) { Text($0.location).lineLimit(1) }
                        .width(min: 180, ideal: 300)
                    TableColumn("Security", value: \.securitySort) { o in
                        if let sec = o.security {
                            Text(securityLabel(sec)).monospacedDigit().foregroundStyle(securityColor(sec))
                        }
                    }
                    TableColumn("Expires", value: \.daysLeftSort) { Text($0.daysLeft.map { "\($0)d" } ?? "–").monospacedDigit() }
                }
                .contextMenu(forSelectionType: MarketOrderRow.ID.self) { ids in
                    if let id = ids.first, let order = (d.sellOrders + d.buyOrders).first(where: { $0.id == id }), let location = order.locationId {
                        PlaceMenu(locationID: location, name: order.location, systemID: order.systemId, systemName: order.system)
                    }
                }
                .frame(height: 240)
            }
        }
    }

    // MARK: Loading

    private func loadSearch() async {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { searchResults = []; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let found = (try? await appState.backend.marketSearch(text)) ?? []
        guard !Task.isCancelled else { return }
        searchResults = found
    }

    private func loadDetail() async {
        guard selectedTypeID != 0 else { detail = nil; return }
        loadingDetail = true
        defer { loadingDetail = false }
        let typeID = selectedTypeID
        do {
            let result = try await appState.backend.marketItem(typeID: typeID, scope: scope, referenceHub: homeHub)
            guard !Task.isCancelled, typeID == selectedTypeID else { return }
            detail = result
            detailError = nil
        } catch {
            guard !Task.isCancelled else { return }
            detailError = error.localizedDescription
            detail = nil
        }
    }

    private func loadWatched() async {
        watched = Set((try? await appState.backend.watchlist()) ?? [])
        watchedItems = watched.isEmpty ? [] : ((try? await appState.backend.marketNames(Array(watched))) ?? [])
    }

    private func toggleWatch(_ typeID: Int) {
        let name = detail?.typeId == typeID ? (detail?.name ?? "Item") : (watchedItems.first { $0.typeId == typeID }?.name ?? "Item")
        appState.toggleWatch(typeID, name: name)
    }
}

/// One item in the market list (icon, name, optional group, watch star).
struct MarketItemRow: View {
    let item: MarketTypeRow
    let showGroup: Bool
    let watched: Bool
    let onToggleWatch: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            AsyncImage(url: PublicESIClient.typeIconURL(typeID: item.typeId, size: 32)) { image in
                image.resizable()
            } placeholder: { Color.clear }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                // Middle truncation keeps the end of the name (Type A / B, I / II) visible.
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if showGroup, let group = item.groupName {
                    Text(group).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if watched {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
            }
        }
        .help(item.name)
        .contextMenu { ItemMenu(typeID: item.typeId, name: item.name, hideMarket: true) }
    }
}

/// A market group that opens like in game: its sub-groups, and – for groups that hold items –
/// the items themselves (read when the group is first opened).
struct MarketGroupBranch: View {
    let node: MarketTreeNode
    let watched: Set<Int>
    let onToggleWatch: (Int) -> Void
    let loadItems: (Int) async -> [MarketTypeRow]

    @State private var expanded = false
    @State private var items: [MarketTypeRow]?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(node.children ?? []) { child in
                MarketGroupBranch(node: child, watched: watched, onToggleWatch: onToggleWatch, loadItems: loadItems)
            }
            if node.hasTypes {
                if let items {
                    ForEach(items) { item in
                        MarketItemRow(item: item, showGroup: false, watched: watched.contains(item.typeId),
                                      onToggleWatch: onToggleWatch)
                            .tag(item.typeId)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        } label: {
            Text(node.name).lineLimit(1).help(node.name)
        }
        .task(id: expanded) {
            if expanded && node.hasTypes && items == nil {
                items = await loadItems(node.id)
            }
        }
    }
}

/// A branch of the search or watchlist tree: closed until you open it (user, 15 Nov), items listed in place.
struct MarketFilteredBranch: View {
    let node: MarketFilteredNode
    let watched: Set<Int>
    let onToggleWatch: (Int) -> Void

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(node.children) { child in
                MarketFilteredBranch(node: child, watched: watched, onToggleWatch: onToggleWatch)
            }
            ForEach(node.items) { item in
                MarketItemRow(item: item, showGroup: false, watched: watched.contains(item.typeId),
                              onToggleWatch: onToggleWatch)
                    .tag(item.typeId)
            }
        } label: {
            Text(node.name).lineLimit(1).help(node.name)
        }
    }
}
