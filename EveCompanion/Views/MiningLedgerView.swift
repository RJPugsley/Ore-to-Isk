import Charts
import SwiftUI

/// What you mined over the history range: totals, a chart by day / week / month, by ore and by system.
struct MiningLedgerView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(HistoryRange.key) private var rangeDays = HistoryRange.defaultDays
    @AppStorage(BuildSettingsKey.materialHub) private var materialHub = BuildSettingsKey.defaultHub
    @AppStorage("mining.groupBy") private var groupBy = Grouping.day.rawValue
    @AppStorage("mining.metric") private var metric = Metric.value.rawValue

    enum Grouping: String, CaseIterable { case day = "Day", week = "Week", month = "Month" }
    enum Metric: String, CaseIterable { case value = "ISK", m3 = "m³", units = "Units" }

    @State private var ledger: MiningLedger?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var refresh = 0
    @State private var oreSort = [KeyPathComparator(\MinedOre.value, order: .reverse)]
    @State private var systemSort = [KeyPathComparator(\MinedSystem.value, order: .reverse)]
    @State private var entrySort = [KeyPathComparator(\MiningEntry.date, order: .reverse)]

    private struct LoadKey: Hashable { var range: Int; var hub: String; var refresh: Int }

    var body: some View {
        Group {
            if let ledger {
                content(ledger)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Mining", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { refresh += 1 }
                }
            } else {
                ProgressView("Reading your mining ledger…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(subtitle)
        .task(id: LoadKey(range: rangeDays, hub: materialHub, refresh: refresh)) { await load() }
    }

    private var subtitle: String {
        guard let ledger else { return "" }
        if let since = ledger.historySince { return "\(ledger.rangeLabel) · ledger since \(since)" }
        return ledger.rangeLabel
    }

    // MARK: Content

    private func content(_ l: MiningLedger) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("Group by", selection: $groupBy) {
                        ForEach(Grouping.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    Picker("Show", selection: $metric) {
                        ForEach(Metric.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    Spacer()
                    Button("Refresh") { refresh += 1 }
                }

                HStack(spacing: 12) {
                    tile("Mined · \(l.rangeLabel)", "\(l.totalUnits.short) units")
                    tile("Volume", "\(Int(l.totalM3.rounded()).short) m³")
                    tile("Value", l.totalValue.iskShort, color: .green)
                        .help("Valued at \(l.hub) buy orders (CCP average if none) – not cash until sold")
                    tile("Days Mined", "\(l.daysMined)")
                }

                GroupBox("\(Metric(rawValue: metric)?.rawValue ?? "ISK") Mined per \(periodLabel) · \(l.rangeLabel)") {
                    chart(l)
                        .frame(height: 200)
                        .padding(6)
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("By Ore").font(.headline)
                        Table(l.byOre.sorted(using: oreSort), sortOrder: $oreSort) {
                            TableColumn("Ore", value: \.name) { ore in
                                HStack(spacing: 6) {
                                    AsyncImage(url: PublicESIClient.typeIconURL(typeID: ore.typeId, size: 32)) { image in
                                        image.resizable()
                                    } placeholder: { Color.clear }
                                    .frame(width: 18, height: 18)
                                    Text(ore.name)
                                }
                            }
                            .width(min: 120, ideal: 160)
                            TableColumn("Units", value: \.units) { Text($0.units.short).monospacedDigit() }
                            TableColumn("m³", value: \.m3) { Text(Int($0.m3.rounded()).short).monospacedDigit() }
                            TableColumn("Value", value: \.value) { ore in
                                Text(ore.value.iskShort).monospacedDigit()
                                    .help("\(ore.unitPrice.isk) each · \(ore.share.percent) of the total")
                            }
                        }
                        .contextMenu(forSelectionType: MinedOre.ID.self) { ids in
                            if let id = ids.first, let ore = l.byOre.first(where: { $0.id == id }) {
                                ItemMenu(typeID: ore.typeId, name: ore.name)
                            }
                        }
                        .frame(height: CGFloat(max(l.byOre.count, 1)) * 26 + 30)
                        .scrollDisabled(true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("By System").font(.headline)
                        Table(l.bySystem.sorted(using: systemSort), sortOrder: $systemSort) {
                            TableColumn("System", value: \.name) { Text($0.name) }
                            TableColumn("Security", value: \.securitySort) { system in
                                if let security = system.security {
                                    Text(securityLabel(security)).monospacedDigit().foregroundStyle(securityColor(security))
                                } else {
                                    Text("–")
                                }
                            }
                            .width(min: 50, ideal: 60)
                            TableColumn("Units", value: \.units) { Text($0.units.short).monospacedDigit() }
                            TableColumn("Value", value: \.value) { Text($0.value.iskShort).monospacedDigit() }
                        }
                        .contextMenu(forSelectionType: MinedSystem.ID.self) { ids in
                            if let id = ids.first, let system = l.bySystem.first(where: { $0.id == id }) {
                                PlaceMenu(locationID: system.systemId, name: system.name)
                            }
                        }
                        .frame(height: CGFloat(max(l.bySystem.count, 1)) * 26 + 30)
                        .scrollDisabled(true)
                    }
                    .frame(maxWidth: 420)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Ledger").font(.headline)
                    Table(l.entries.sorted(using: entrySort), sortOrder: $entrySort) {
                        TableColumn("Date", value: \.date) { Text($0.date).monospacedDigit() }
                            .width(min: 80, ideal: 100)
                        TableColumn("Ore", value: \.name) { Text($0.name) }
                        TableColumn("System", value: \.place) { Text($0.place).foregroundStyle(.secondary) }
                        TableColumn("Units", value: \.units) { Text($0.units.short).monospacedDigit() }
                        TableColumn("m³", value: \.m3) { Text(Int($0.m3.rounded()).short).monospacedDigit() }
                        TableColumn("Value", value: \.value) { Text($0.value.iskShort).monospacedDigit() }
                    }
                    .contextMenu(forSelectionType: MiningEntry.ID.self) { ids in
                        if let id = ids.first, let entry = l.entries.first(where: { $0.id == id }) {
                            ItemMenu(typeID: entry.typeId, name: entry.name)
                            PlaceMenu(locationID: entry.systemId, name: entry.system ?? "System")
                        }
                    }
                    .frame(height: min(CGFloat(max(l.entries.count, 1)) * 26 + 30, 360))
                    .overlay {
                        if l.entries.isEmpty {
                            ContentUnavailableView("Nothing Mined", systemImage: "hammer",
                                                   description: Text("No mining recorded in this range (\(l.rangeLabel))."))
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: Chart

    private struct Bucket: Identifiable {
        let start: Date      // first day in the bucket
        let end: Date        // the moment after its last day
        let amount: Double
        var id: Date { start }
    }

    /// Days in each bucket. Week and Month are rolling periods counted back from today
    /// (7 and 30 days), not calendar weeks or months, so the latest bucket always ends today.
    private var periodLabel: String {
        switch Grouping(rawValue: groupBy) ?? .day {
        case .day: return "Day"
        case .week: return "7 Days"
        case .month: return "30 Days"
        }
    }

    private func bucketDays(_ grouping: Grouping) -> Int {
        switch grouping {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    private func buckets(_ l: MiningLedger) -> [Bucket] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let grouping = Grouping(rawValue: groupBy) ?? .day
        let length = bucketDays(grouping)
        let rangeStart = calendar.startOfDay(for: l.daily.first?.day ?? .now)
        let lastDay = calendar.startOfDay(for: l.daily.last?.day ?? .now)
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay

        var totals: [Int: Double] = [:]
        for day in l.daily {
            let date = calendar.startOfDay(for: day.day)
            let daysBack = calendar.dateComponents([.day], from: date, to: lastDay).day ?? 0
            let index = max(daysBack, 0) / length
            let amount: Double
            switch Metric(rawValue: metric) ?? .value {
            case .value: amount = day.value
            case .m3: amount = day.m3
            case .units: amount = Double(day.units)
            }
            totals[index, default: 0] += amount
        }

        // Every bucket from today back to the start of the range, empty ones as 0.
        var result: [Bucket] = []
        var index = 0
        while true {
            let end = calendar.date(byAdding: .day, value: -index * length, to: rangeEnd) ?? rangeEnd
            if end <= rangeStart { break }
            let start = max(calendar.date(byAdding: .day, value: -length, to: end) ?? end, rangeStart)
            result.append(Bucket(start: start, end: end, amount: totals[index] ?? 0))
            index += 1
        }
        return result.reversed()
    }

    private struct ChartPoint: Identifiable {
        let date: Date
        let amount: Double
        let id: Int
    }

    private func chart(_ l: MiningLedger) -> some View {
        let data = buckets(l)
        let daily = (Grouping(rawValue: groupBy) ?? .day) == .day
        // Day: one point per day. Week / Month: each bucket drawn flat across the days it covers.
        var points: [ChartPoint] = []
        for bucket in data {
            if daily {
                points.append(ChartPoint(date: bucket.start, amount: bucket.amount, id: points.count))
            } else {
                points.append(ChartPoint(date: bucket.start, amount: bucket.amount, id: points.count))
                points.append(ChartPoint(date: bucket.end, amount: bucket.amount, id: points.count))
            }
        }
        let start = data.first?.start ?? .now
        let end = daily ? (data.last?.start ?? .now) : (data.last?.end ?? .now)
        let long = end.timeIntervalSince(start) > 92 * 86400
        let isValue = (Metric(rawValue: metric) ?? .value) == .value
        return Chart(points) { point in
            LineMark(x: .value("Date", point.date), y: .value("Mined", point.amount))
                .lineStyle(ChartStyle.line)
                .foregroundStyle(Color.green)
                .interpolationMethod(daily ? .monotone : .linear)
            AreaMark(x: .value("Date", point.date), y: .value("Mined", point.amount))
                .foregroundStyle(.linearGradient(colors: [Color.green.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(daily ? .monotone : .linear)
        }
        .chartXScale(domain: start...end)
        .chartXAxis {
            AxisMarks(values: .stride(by: long ? .month : .weekOfYear)) { _ in
                AxisGridLine()
                AxisValueLabel(format: long ? Date.FormatStyle.dateTime.month(.abbreviated).year(.twoDigits)
                                            : Date.FormatStyle.dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(isValue ? amount.iskShort.replacingOccurrences(of: " ISK", with: "")
                                     : amount.short)
                    }
                }
            }
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

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            ledger = try await appState.backend.miningLedger(hub: materialHub)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
