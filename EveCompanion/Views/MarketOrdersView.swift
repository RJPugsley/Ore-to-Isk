import SwiftUI

// MARK: - Models (/market/my-orders)

struct MyOrdersSummary: Decodable {
    let checkedAt: Date
    let orderSlots: Int?
    let sellCount: Int
    let buyCount: Int
    let sellValue: Double
    /// What's left on your sell orders after sales tax, fees and what the items cost you.
    let sellNetValue: Double?
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
    // Sell orders only (19 Nov 2026): what's left is really worth.
    let netLeft: Double?
    let taxLeft: Double?
    let salesTaxRate: Double?
    let brokerRate: Double?
    let brokerEstimated: Bool?
    let listingFee: Double?
    let relistFees: Double?
    let relists: Int?
    let feesPaid: Double?
    let feesShare: Double?
    let costEach: Double?
    let costLeft: Double?
    // Regional history (19 Nov 2026): the fair price and how fast it sells.
    let fairPrice: Double?
    let fairTrend: String?
    let soldPerDay: Double?
    let daysToSell: Double?
    let otherBelowFair: Bool?

    var id: Int { orderId }
    var netSort: Double { isBuy ? escrow : (netLeft ?? valueLeft) }
    var fairSort: Double { fairPrice ?? 0 }
    var soldSort: Double { soldPerDay ?? -1 }
    /// Your price against the fair price: + = you're above it.
    var vsFair: Double? {
        guard let fairPrice, fairPrice > 0 else { return nil }
        return price / fairPrice - 1
    }
    /// Signed gap: + when the best other price is above yours, − when below.
    var signedGap: Double? {
        guard let bestOther, price > 0 else { return nil }
        return (bestOther - price) / price
    }
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
    @State private var highlight = RowHighlights()
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
            tile("Sell Orders", "\(s.sellCount)",
                 detail: "\(s.sellValue.iskShort) listed" + (s.sellNetValue.map { " · \($0.iskShort) net" } ?? ""))
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

                Table(r.orders.sorted(using: resultSort), selection: highlight.row("t185"), sortOrder: $resultSort) {
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
            TableColumn("", value: \.beatenSort) { o in
                if o.beaten {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                        .help(buy ? "Outbid – someone pays more" : "Undercut – someone sells cheaper")
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Color.green)
                        .help(o.bestOther == nil ? "Only order here" : (buy ? "Highest buy order" : "Cheapest sell order"))
                }
            }
            .width(22)

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

            TableColumn(buy ? "Yours / Highest Other" : "Yours / Lowest Other", value: \.price) { o in
                HStack(spacing: 4) {
                    Text(o.price.isk).bold()
                    Text("/").foregroundStyle(.secondary)
                    if let other = o.bestOther {
                        Text(other.isk)
                        if let gap = o.signedGap {
                            Text("(\(gap >= 0 ? "+" : "−")\(String(format: "%.2f", abs(gap) * 100))%)")
                                .foregroundStyle(o.beaten ? Color.orange : Color.green)
                        }
                        if o.otherBelowFair == true {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(Color.orange)
                                .help("The cheapest other seller is well below the fair price – probably a one-off dump. It may be worth waiting rather than matching it.")
                        }
                    } else {
                        Text("–").foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
                .help("Yours: \(o.price.iskExact)" + (o.bestOther.map { "\nBest other: \($0.iskExact)" } ?? "")
                      + "\n\(o.competingUnits.short) units on other \(buy ? "buy" : "sell") orders at this station")
            }
            .width(min: 170, ideal: 210)

            TableColumn("Fair Price", value: \.fairSort) { o in
                if let fair = o.fairPrice {
                    HStack(spacing: 4) {
                        Text(fair.isk)
                        if o.fairTrend == "up" { Image(systemName: "arrow.up.right").foregroundStyle(.secondary) }
                        if o.fairTrend == "down" { Image(systemName: "arrow.down.right").foregroundStyle(.secondary) }
                        if let vs = o.vsFair {
                            Text("(\(vs >= 0 ? "+" : "−")\(String(format: "%.0f", abs(vs) * 100))%)")
                                .foregroundStyle(fairColour(vs, buy: buy))
                        }
                    }
                    .monospacedDigit()
                    .help("What it normally sells for in the region lately (the middle of recent sales; follows a real trend – the same green line as on the Market chart). The % is your price against it.\nExact: \(fair.iskExact)")
                } else {
                    Text("–").foregroundStyle(.secondary).help("No recent sales in the region to go by.")
                }
            }
            .width(min: 110, ideal: 130)

            TableColumn("Sold / Day", value: \.soldSort) { o in
                if let sold = o.soldPerDay {
                    Text(sold >= 10 ? sold.short : String(format: "%.1f", sold))
                        .monospacedDigit()
                        .help(soldHelp(o, sold))
                } else {
                    Text("–").foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 75)

            TableColumn("Remaining", value: \.volumeRemain) { o in
                Text("\(o.volumeRemain.short) / \(o.volumeTotal.short)").monospacedDigit()
            }
            .width(min: 80, ideal: 100)

            TableColumn(buy ? "Escrow" : "Net Left", value: \.netSort) { o in
                if buy {
                    Text(o.escrow.iskShort).monospacedDigit()
                } else {
                    let net = o.netLeft ?? o.valueLeft
                    Text(net.iskShort).monospacedDigit()
                        .foregroundStyle(net < 0 ? Color.red : Color.primary)
                        .help(netHelp(o))
                }
            }

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

    /// Orange when your price is well above fair (sell) or well below it (buy) – it'll sit; green otherwise.
    private func fairColour(_ vs: Double, buy: Bool) -> Color {
        let off = buy ? -vs : vs
        return off > 0.10 ? Color.orange : Color.green
    }

    private func soldHelp(_ o: MyOrder, _ sold: Double) -> String {
        var text = "About \(sold >= 10 ? sold.short : String(format: "%.1f", sold)) sold per day in the region (whole market, every seller)."
        if let days = o.daysToSell {
            text += "\nYour \(o.volumeRemain.short) left is about \(days < 1 ? "less than a day" : String(format: "%.0f days", days)) of the region's sales – you share them with the other sellers, so expect longer."
        }
        return text
    }

    /// The sums behind Net Left.
    private func netHelp(_ o: MyOrder) -> String {
        var lines = ["\(o.volumeRemain.short) left × \(o.price.isk) = \(o.valueLeft.iskShort)"]
        if let tax = o.taxLeft {
            lines.append("− Sales tax \(tax.iskShort) (\((o.salesTaxRate ?? 0).percent))")
        }
        if let share = o.feesShare {
            var fee = "− Broker fees \(share.iskShort)"
            if let paid = o.feesPaid, o.volumeRemain < o.volumeTotal {
                fee += " (share of \(paid.iskShort) paid on this order)"
            }
            lines.append(fee)
            var detail = "    listing \((o.listingFee ?? 0).iskShort)"
            if let relists = o.relists, relists > 0 {
                detail += " + \(relists) price change\(relists == 1 ? "" : "s") \((o.relistFees ?? 0).iskShort)"
            }
            detail += " at \((o.brokerRate ?? 0).percent)\(o.brokerEstimated == true ? " (estimated – the structure owner sets it)" : "")"
            lines.append(detail)
        }
        if let each = o.costEach {
            lines.append("− What they cost you \((o.costLeft ?? 0).iskShort) (\(each.isk) each – built or bought)")
        } else {
            lines.append("− No ISK cost recorded (mined, looted or owned before the app's history)")
        }
        lines.append("= \((o.netLeft ?? o.valueLeft).iskShort)")
        lines.append("Price changes are the ones the app saw while open.")
        return lines.joined(separator: "\n")
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
