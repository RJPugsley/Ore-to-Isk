import Charts
import SwiftUI

// MARK: - Models (/finances/summary)

struct FinanceSummary: Decodable {
    let days: Int
    let rangeLabel: String?
    let historySince: String?
    let netWorth: NetWorth
    let netWorthHistory: [NetWorthPoint]?
    let monthly: [FinanceMonth]?
    let income: Double
    let spending: Double
    let net: Double
    let daily: [FinanceDay]
    let categories: [FinanceCategory]
    let activities: [FinanceActivity]
    let transactions: [FinanceTransaction]
}

struct NetWorth: Decodable {
    let total: Double
    let wallet: Double
    let assets: Double
    let sellOrders: Double
    let escrow: Double
}

struct FinanceDay: Decodable, Identifiable {
    let date: String
    let net: Double
    let income: Double?
    let spending: Double?
    var id: String { date }
    var day: Date {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        return parser.date(from: date) ?? .now
    }
}

struct FinanceCategory: Decodable, Identifiable {
    let name: String
    let income: Double
    let spending: Double
    var id: String { name }
    var net: Double { income - spending }
}

struct FinanceActivity: Decodable, Identifiable {
    let name: String
    let income: Double
    let costs: Double
    let net: Double
    let detail: String
    let lines: [FinanceLine]
    var id: String { name }

    var symbol: String {
        switch name {
        case "Mining": "hammer.circle"
        case "Manufacturing": "gearshape.2"
        case "Trading": "arrow.left.arrow.right"
        default: "percent"
        }
    }
}

struct FinanceLine: Decodable, Identifiable {
    let name: String
    let amount: Double
    let units: Int?
    var id: String { name }
}

struct FinanceTransaction: Decodable, Identifiable {
    let transactionId: Int
    let date: Date
    let typeId: Int
    let name: String
    let quantity: Int
    let unitPrice: Double
    let total: Double
    let isBuy: Bool
    let location: String?
    var id: Int { transactionId }
    var kind: String { isBuy ? "Buy" : "Sell" }
    var place: String { location ?? "" }
}

// MARK: - View

struct FinancesView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(BuildSettingsKey.materialHub) private var materialHub = BuildSettingsKey.defaultHub
    @AppStorage(HistoryRange.key) private var rangeDays = HistoryRange.defaultDays

    private enum Tab: String, CaseIterable { case overview = "Overview", transactions = "Transactions" }

    @State private var tab: Tab = .overview
    @State private var summary: FinanceSummary?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\FinanceTransaction.date, order: .reverse)]
    @State private var selection: FinanceTransaction.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Spacer()
                Button("Refresh") { Task { await load() } }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()

            if let summary {
                switch tab {
                case .overview: overview(summary)
                case .transactions: transactions(summary)
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Finances", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ProgressView("Reading your wallet, assets and transactions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(summary.map(subtitle) ?? "")
        .task(id: rangeDays) { await load() }
    }

    // MARK: Overview

    private func rangeText(_ s: FinanceSummary) -> String {
        s.rangeLabel ?? "\(s.days) Days"
    }

    private func subtitle(_ s: FinanceSummary) -> String {
        guard let since = s.historySince.flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return rangeText(s) }
        return "\(rangeText(s)) · history since \(since.formatted(date: .abbreviated, time: .omitted))"
    }

    private func overview(_ s: FinanceSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1. Tiles
                HStack(spacing: 12) {
                    tile("Wallet", s.netWorth.wallet.iskShort)
                    tile("Net Worth", s.netWorth.total.iskShort)
                        .help("""
                        Wallet \(s.netWorth.wallet.iskShort)
                        Items you own \(s.netWorth.assets.iskShort) (CCP estimated prices)
                        Sell orders listed \(s.netWorth.sellOrders.iskShort)
                        Buy order escrow \(s.netWorth.escrow.iskShort)
                        """)
                    tile("In · \(rangeText(s))", s.income.iskShort, color: .green)
                    tile("Out · \(rangeText(s))", s.spending.iskShort, color: .red)
                    tile("Net · \(rangeText(s))", s.net.iskShort, color: s.net >= 0 ? .green : .red)
                }

                // 2. Daily chart + categories
                GroupBox("ISK In and Out per Day · \(rangeText(s))") {
                    HStack(alignment: .top, spacing: 20) {
                        flowChart(s)
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(s.categories.prefix(9)) { category in
                                HStack {
                                    Text(category.name)
                                    Spacer()
                                    Text(category.net >= 0 ? "+\(category.net.iskShort)" : category.net.iskShort)
                                        .monospacedDigit()
                                        .foregroundStyle(category.net >= 0 ? Color.green : Color.red)
                                }
                                .help("In \(category.income.iskShort) · out \(category.spending.iskShort)")
                            }
                        }
                        .frame(width: 280)
                    }
                    .padding(6)
                }

                // 3. Net worth over time
                GroupBox("Net Worth Over Time") {
                    netWorthChart(s)
                        .padding(6)
                }

                // 4. Profit by activity
                GroupBox("Where Your Money Came From") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 16) {
                        ForEach(s.activities) { activityCard($0) }
                    }
                    .padding(6)
                }
            }
            .padding(16)
        }
    }

    /// One point per day across the whole range (days with nothing = 0), In and Out as two lines.
    @ViewBuilder
    private func flowChart(_ s: FinanceSummary) -> some View {
        let (start, end, long) = chartRange(s)
        Chart {
            ForEach(s.daily) { day in
                LineMark(x: .value("Day", day.day, unit: .day), y: .value("ISK", day.income ?? max(day.net, 0)))
                    .lineStyle(ChartStyle.line)
                    .foregroundStyle(by: .value("Flow", "In"))
                LineMark(x: .value("Day", day.day, unit: .day), y: .value("ISK", day.spending ?? max(-day.net, 0)))
                    .lineStyle(ChartStyle.line)
                    .foregroundStyle(by: .value("Flow", "Out"))
            }
        }
        .chartForegroundStyleScale(["In": Color.green, "Out": Color.red])
        .chartXScale(domain: start...end)
        .chartXAxis { dayAxis(long: long) }
        .chartYAxis { iskAxis }
        .chartLegend(position: .top, alignment: .leading)
    }

    /// The date range both Finances charts share, so their time scales line up.
    private func chartRange(_ s: FinanceSummary) -> (start: Date, end: Date, long: Bool) {
        let start = s.daily.first?.day ?? .now
        let end = s.daily.last?.day ?? .now
        return (start, end, end.timeIntervalSince(start) > 92 * 86400)
    }

    private func dayAxis(long: Bool) -> some AxisContent {
        AxisMarks(values: .stride(by: long ? .month : .weekOfYear)) { _ in
            AxisGridLine()
            AxisValueLabel(format: long ? Date.FormatStyle.dateTime.month(.abbreviated).year(.twoDigits)
                                        : Date.FormatStyle.dateTime.day().month(.abbreviated))
        }
    }

    private var iskAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine()
            AxisValueLabel {
                if let amount = value.as(Double.self) {
                    Text(amount.iskShort.replacingOccurrences(of: " ISK", with: ""))
                }
            }
        }
    }

    @ViewBuilder
    private func netWorthChart(_ s: FinanceSummary) -> some View {
        let points = (s.netWorthHistory ?? []).filter { $0.total != nil }
        let (start, end, long) = chartRange(s)
        if !points.isEmpty {
            // Same time scale as the In/Out chart above: the full history range, one point per day.
            Chart(points) { point in
                LineMark(x: .value("Day", point.day, unit: .day), y: .value("Net worth", point.total ?? 0))
                    .lineStyle(ChartStyle.line)
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Day", point.day, unit: .day), y: .value("Net worth", point.total ?? 0))
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                PointMark(x: .value("Day", point.day, unit: .day), y: .value("Net worth", point.total ?? 0))
                    .symbolSize(points.count < 15 ? 20 : 0)
            }
            .chartXScale(domain: start...end)
            .chartXAxis { dayAxis(long: long) }
            .chartYAxis { iskAxis }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 160)
        } else {
            Text("Net worth is saved once a day when you open the app – the first point appears after today's refresh.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tile(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).bold().monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func activityCard(_ a: FinanceActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(a.name, systemImage: a.symbol).font(.headline)
                Spacer()
                Text(a.net >= 0 ? "+\(a.net.iskShort)" : a.net.iskShort)
                    .font(.headline).monospacedDigit()
                    .foregroundStyle(a.net >= 0 ? Color.green : Color.red)
            }
            ForEach(a.lines) { line in
                HStack {
                    Text(line.name).foregroundStyle(.secondary)
                    if let units = line.units {
                        Text("\(units.short) units").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(line.amount.iskShort).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Text(a.detail).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Transactions

    private func transactions(_ s: FinanceSummary) -> some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let rows = s.transactions
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.place.localizedCaseInsensitiveContains(q) }
            .sorted(using: sortOrder)
        return VStack(spacing: 0) {
            HStack {
                SuggestingSearchField(prompt: "Search item or station", text: $search, width: 260) { text in
                    localSuggestions(text, from: s.transactions.map(\.name) + s.transactions.map(\.place))
                }
                Spacer()
                let sold = rows.filter { !$0.isBuy }.reduce(0) { $0 + $1.total }
                let bought = rows.filter(\.isBuy).reduce(0) { $0 + $1.total }
                Text("\(rows.count) transactions · sold \(sold.iskShort) · bought \((-bought).iskShort)")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .zIndex(1)   // search suggestions draw over the table

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Date", value: \.date) { t in
                    Text(t.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                }
                .width(min: 120, ideal: 140)
                TableColumn("Type", value: \.kind) { t in
                    Text(t.kind).foregroundStyle(t.isBuy ? Color.red : Color.green)
                }
                .width(min: 40, ideal: 50)
                TableColumn("Item", value: \.name) { t in
                    HStack(spacing: 6) {
                        AsyncImage(url: PublicESIClient.typeIconURL(typeID: t.typeId, size: 32)) { image in
                            image.resizable()
                        } placeholder: { Color.clear }
                        .frame(width: 18, height: 18)
                        Text(t.name)
                    }
                }
                .width(min: 150, ideal: 200)
                TableColumn("Qty", value: \.quantity) { t in
                    Text(t.quantity.short).monospacedDigit()
                }
                .width(min: 50, ideal: 70)
                TableColumn("Price Each", value: \.unitPrice) { t in
                    Text(t.unitPrice.iskShort).monospacedDigit()
                }
                TableColumn("Total", value: \.total) { t in
                    Text(t.total.iskShort).monospacedDigit().bold()
                        .foregroundStyle(t.isBuy ? Color.red : Color.green)
                }
                TableColumn("Where", value: \.place) { t in
                    Text(t.place).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 150, ideal: 260)
            }
            .contextMenu(forSelectionType: FinanceTransaction.ID.self) { ids in
                if let id = ids.first, let t = rows.first(where: { $0.id == id }) {
                    ItemMenu(typeID: t.typeId, name: t.name)
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Transactions", systemImage: "list.bullet.rectangle",
                                           description: Text(q.isEmpty ? "Nothing bought or sold in this range (\(rangeText(s)))." : "Nothing matches “\(q)”."))
                }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            summary = try await appState.backend.finances(oreHub: materialHub)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
