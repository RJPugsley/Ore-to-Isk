import SwiftUI

// MARK: - Models (/market/my-orders)

struct MyOrdersSummary: Decodable {
    let checkedAt: Date
    let orderSlots: Int?
    let sellCount: Int
    let buyCount: Int
    let sellValue: Double
    let escrow: Double
    let beatenCount: Int
    let orders: [MyOrder]
}

struct MyOrder: Decodable, Identifiable {
    let orderId: Int
    let typeId: Int
    let name: String
    let station: String?
    let locationId: Int?
    let isBuy: Bool
    let price: Double
    let volumeRemain: Int
    let volumeTotal: Int
    let valueLeft: Double
    let escrow: Double
    let issued: Date
    let expires: Date
    let bestOther: Double?
    let beaten: Bool
    let competingUnits: Int

    var id: Int { orderId }
    var place: String { station ?? "" }
    var bestOtherSort: Double { bestOther ?? 0 }
    var beatenSort: Int { beaten ? 1 : 0 }
    /// How far the best competitor is from you, e.g. 1.6% cheaper.
    var gapPercent: Double? {
        guard let bestOther, price > 0 else { return nil }
        return abs(price - bestOther) / price
    }
}

// MARK: - View

/// Your active buy and sell orders, and whether you've been undercut or outbid.
struct MarketOrdersView: View {
    @Environment(AppState.self) private var appState

    private enum Side: String, CaseIterable { case sell = "Sell Orders", buy = "Buy Orders", results = "Results" }

    @State private var side: Side = .sell
    @State private var summary: MyOrdersSummary?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var selection: MyOrder.ID?
    @State private var sortOrder = [KeyPathComparator(\MyOrder.beatenSort, order: .reverse)]
    @State private var results: OrderResults?
    @State private var resultsError: String?
    @State private var resultSort = [KeyPathComparator(\FinishedOrder.finished, order: .reverse)]
    @AppStorage(HistoryRange.key) private var rangeDays = HistoryRange.defaultDays

    private struct ResultsKey: Hashable { var showing: Bool; var rangeDays: Int }

    private var rows: [MyOrder] {
        (summary?.orders ?? []).filter { $0.isBuy == (side == .buy) }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let summary {
                tiles(summary)
                Divider()
                HStack {
                    Picker("", selection: $side) {
                        Text("Sell Orders (\(summary.sellCount))").tag(Side.sell)
                        Text("Buy Orders (\(summary.buyCount))").tag(Side.buy)
                        Text("Results").tag(Side.results)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 400)
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Checked \(summary.checkedAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                            .help("Competitors' prices are re-checked every 5 minutes while this page is open")
                    }
                    Button("Refresh") { Task { await load(fresh: true) } }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if side == .results {
                    resultsView
                } else {
                    table
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Orders", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load(fresh: true) } }
                }
            } else {
                ProgressView("Checking your orders against the market…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load(fresh: false) }
        .task(id: ResultsKey(showing: side == .results, rangeDays: rangeDays)) {
            guard side == .results else { return }
            do {
                results = try await appState.backend.orderResults()
                resultsError = nil
            } catch {
                resultsError = error.localizedDescription
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await load(fresh: false)
            }
        }
    }

    // MARK: Tiles

    private func tiles(_ s: MyOrdersSummary) -> some View {
        HStack(spacing: 12) {
            tile("Sell Orders", "\(s.sellCount)", detail: "\(s.sellValue.iskShort) listed")
            tile("Buy Orders", "\(s.buyCount)", detail: "\(s.escrow.iskShort) in escrow")
            tile(s.beatenCount == 0 ? "All Orders on Top" : "Undercut / Outbid",
                 "\(s.beatenCount)",
                 detail: s.beatenCount == 0 ? "nobody has beaten your price" : "need a price update",
                 color: s.beatenCount == 0 ? .green : .orange)
            if let slots = s.orderSlots {
                let used = s.sellCount + s.buyCount
                tile("Order Slots", "\(used) / \(slots)", detail: "\(max(slots - used, 0)) free",
                     color: used >= slots ? .red : .primary)
                    .help("5 + 4 per Trade level + 8 per Retail + 16 per Wholesale + 32 per Tycoon")
            }
        }
        .padding(16)
    }

    private func tile(_ title: String, _ value: String, detail: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).bold().monospacedDigit().foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Results (finished orders, from your history)

    @ViewBuilder
    private var resultsView: some View {
        if let r = results {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    tile("Finished · \(r.rangeLabel)", "\(r.finished)",
                         detail: "\(r.filled) filled · \(r.partFilled) part · \(r.unsold) unsold · \(r.cancelled) cancelled")
                    tile("Time to Fill", r.averageHoursToFill.map { ($0 * 3600).durationLabel } ?? "–",
                         detail: "average for filled orders")
                    tile("Got vs Listed", r.gotVsListed.map { $0.percent } ?? "–",
                         detail: "what trades paid vs your order price",
                         color: (r.gotVsListed ?? 1) < 0.999 ? .orange : .primary)
                    tile("Undercut / Outbid", r.beatenShare.map { $0.percent } ?? "–",
                         detail: r.averageGap.map { "of \(r.checks) checks · avg gap \($0.percent)" } ?? "of \(r.checks) checks",
                         color: (r.beatenShare ?? 0) > 0.3 ? .orange : .primary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Table(r.orders.sorted(using: resultSort), sortOrder: $resultSort) {
                    TableColumn("Outcome", value: \.outcome) { o in
                        Text(o.outcome)
                            .foregroundStyle(o.outcome == "Filled" ? Color.green : (o.unitsTraded > 0 ? Color.primary : Color.orange))
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Side", value: \.side) { o in
                        Text(o.side).foregroundStyle(o.isBuy ? Color.red : Color.green)
                    }
                    .width(min: 40, ideal: 50)
                    TableColumn("Item", value: \.name) { o in
                        HStack(spacing: 6) {
                            AsyncImage(url: PublicESIClient.typeIconURL(typeID: o.typeId, size: 32)) { image in
                                image.resizable()
                            } placeholder: { Color.clear }
                            .frame(width: 18, height: 18)
                            Text(o.name)
                        }
                    }
                    .width(min: 140, ideal: 180)
                    TableColumn("Station", value: \.place) { o in
                        Text(o.place).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .width(min: 120, ideal: 200)
                    TableColumn("Your Price", value: \.price) { o in
                        Text(o.price.iskShort).monospacedDigit()
                    }
                    TableColumn("Traded", value: \.unitsTraded) { o in
                        Text("\(o.unitsTraded.short) / \(o.volumeTotal.short)").monospacedDigit()
                    }
                    TableColumn("Got Each", value: \.averageTradeSort) { o in
                        Text(o.averageTradePrice?.iskShort ?? "–").monospacedDigit()
                    }
                    TableColumn("Listed", value: \.issued) { o in
                        Text(o.issued.formatted(date: .abbreviated, time: .omitted)).monospacedDigit()
                    }
                    TableColumn("Took", value: \.duration) { o in
                        Text(o.duration.durationLabel).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .overlay {
                    if r.orders.isEmpty {
                        ContentUnavailableView("No Finished Orders", systemImage: "clock",
                                               description: Text("Orders that fill, expire or get cancelled show up here (\(r.rangeLabel))."))
                    }
                }
            }
        } else if let resultsError {
            ContentUnavailableView("Couldn't Load Results", systemImage: "exclamationmark.triangle",
                                   description: Text(resultsError))
        } else {
            ProgressView("Reading your order history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Table

    private var table: some View {
        let buy = side == .buy
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Status", value: \.beatenSort) { o in
                if o.beaten {
                    Label(buy ? "Outbid" : "Undercut", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                } else {
                    Label(o.bestOther == nil ? "Only order" : (buy ? "Highest" : "Cheapest"),
                          systemImage: "checkmark.circle")
                        .foregroundStyle(Color.green)
                }
            }
            .width(min: 90, ideal: 105)

            TableColumn("Item", value: \.name) { o in
                HStack(spacing: 6) {
                    AsyncImage(url: PublicESIClient.typeIconURL(typeID: o.typeId, size: 32)) { image in
                        image.resizable()
                    } placeholder: { Color.clear }
                    .frame(width: 18, height: 18)
                    Text(o.name)
                }
            }
            .width(min: 130, ideal: 170)

            TableColumn("Station", value: \.place) { o in
                Text(o.place).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 200)

            TableColumn("Your Price", value: \.price) { o in
                Text(o.price.isk).monospacedDigit().bold()
                    .help("Exact: \(o.price.iskExact)")
            }

            TableColumn(buy ? "Highest Other" : "Lowest Other", value: \.bestOtherSort) { o in
                if let other = o.bestOther {
                    HStack(spacing: 4) {
                        Text(other.isk).monospacedDigit()
                        if o.beaten, let gap = o.gapPercent {
                            Text("(\(gap.percent))").foregroundStyle(Color.orange)
                        }
                    }
                    .help("Exact: \(other.iskExact)\n\(o.competingUnits.short) units on other \(buy ? "buy" : "sell") orders at this station")
                } else {
                    Text("–").foregroundStyle(.secondary)
                }
            }

            TableColumn("Remaining", value: \.volumeRemain) { o in
                Text("\(o.volumeRemain.short) / \(o.volumeTotal.short)").monospacedDigit()
            }
            .width(min: 80, ideal: 100)

            TableColumn(buy ? "Escrow" : "Value Left", value: \.valueLeft) { o in
                Text((buy ? o.escrow : o.valueLeft).iskShort).monospacedDigit()
            }

            TableColumn("Listed", value: \.issued) { o in
                Text(o.issued, style: .relative).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Expires", value: \.expires) { o in
                Text(o.expires.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(o.expires.timeIntervalSinceNow < 3 * 86_400 ? Color.orange : Color.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: MyOrder.ID.self) { ids in
            if let id = ids.first, let order = rows.first(where: { $0.id == id }) {
                Button("Update Price – Open Market in Game") { appState.showInGame(order.typeId, market: true, name: order.name) }
                ItemMenu(typeID: order.typeId, name: order.name, quantity: order.volumeRemain)
                if let location = order.locationId {
                    PlaceMenu(locationID: location, name: order.place)
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(buy ? "No Buy Orders" : "No Sell Orders",
                                       systemImage: "cart",
                                       description: Text("You have no active \(buy ? "buy" : "sell") orders."))
            }
        }
    }

    // MARK: Loading

    private func load(fresh: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            summary = try await appState.backend.myOrders(fresh: fresh)
            errorMessage = nil
        } catch {
            if summary == nil { errorMessage = error.localizedDescription }
        }
    }
}
