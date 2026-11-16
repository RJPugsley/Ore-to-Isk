import SwiftUI

// MARK: - Shared price-check settings and badges (engine: Services/Engine/FairPrice.swift)

/// UserDefaults keys for the Price Checks menu – read by the engine too (FairPrice.Settings.current).
enum PriceCheckKey {
    static let band = "priceCheck.band"                // percent, default 50
    static let lookbackDays = "priceCheck.lookbackDays" // default 30
    static let batchRuns = "priceCheck.batchRuns"      // default 10 (Build vs Sell, Blueprint Payback)
}

/// The engine's verdict on one price (FairPrice.check).
struct PriceCheck: Decodable {
    let live: Double?
    let fair: Double?
    let used: Double?
    let status: String
    let trend: String?
    let ratio: Double?
    let thin: Bool?
    let speed: String?
    let speedReason: String?
    let daysToSell: Double?
    let soldPerDay: Double?
    let soldPerDay7: Double?
    /// Median daily price over the last 7 days and over the whole lookback.
    let median7: Double?
    let medianLookback: Double?

    /// Which way the price has moved lately: last 7 days' median against the lookback median.
    /// "up" / "down" once it's moved more than 2%, "flat" otherwise, nil without history.
    var priceDirection: String? {
        guard let median7, let medianLookback, medianLookback > 0 else { return nil }
        let change = median7 / medianLookback - 1
        if change > 0.02 { return "up" }
        if change < -0.02 { return "down" }
        return "flat"
    }

    var priceChangePercent: Double? {
        guard let median7, let medianLookback, medianLookback > 0 else { return nil }
        return median7 / medianLookback - 1
    }

    var isFlagged: Bool { status == "inflated" || status == "dumped" }
}

struct PriceBadge: Identifiable {
    /// price = about the price itself (Inflated, Dumped, No history, ↑ / ↓) – shown by the price.
    /// market = how the market behaves (Quick, Slow, Tight, Wide) – shown by sold per day.
    enum Kind { case price, market }

    let text: String
    let color: Color
    let help: String
    var kind: Kind = .price
    var id: String { text }

    /// Badges explaining a checked price. `what` names the batch ("10 Ventures").
    static func badges(_ check: PriceCheck?, place: String, lookback: Int, what: String,
                       sellSide: Bool = true, spread: String? = nil, buying: Bool = false) -> [PriceBadge] {
        guard let check else { return [] }
        var badges: [PriceBadge] = []
        let fairText = check.fair?.isk ?? "–"
        let liveText = check.live?.isk ?? "–"
        let percent = check.ratio.map { Int((abs($0 - 1) * 100).rounded()) } ?? 0
        let orders = sellSide ? "price" : "buy orders"
        switch check.status {
        case "inflated":
            badges.append(PriceBadge(text: "Inflated", color: .orange,
                help: "\(place) \(orders) \(liveText) is \(percent)% above the fair price \(fairText) (median of daily sales over \(lookback) days). " + (buying ? "You'd still pay the listing price – worth waiting or looking at another hub." : "The fair price is used.")))
        case "dumped":
            badges.append(PriceBadge(text: "Dumped", color: .purple,
                help: "\(place) \(orders) \(liveText) is \(percent)% below the fair price \(fairText). " + (buying ? "A bargain if it's real – check the listing before it goes." : "The live price is kept – it's what you'd actually get.")))
        case "no_history":
            badges.append(PriceBadge(text: "No history", color: .secondary,
                help: "No sales in \(place)'s region over \(lookback) days, so the price can't be checked. The live price is used."))
        default:
            break
        }
        if let trend = check.trend {
            let up = trend == "up"
            badges.append(PriceBadge(text: up ? "↑" : "↓", color: .blue,
                help: "Price trending \(up ? "up" : "down"): the last 7 days' median has moved clearly from the \(lookback)-day median, with real volume behind it – the fair price follows the newer level."))
        }
        let perDay = check.soldPerDay.map { formatRate($0) } ?? "0"
        let perDay7 = check.soldPerDay7.map { formatRate($0) } ?? "0"
        switch check.speed {
        case "quick":
            badges.append(PriceBadge(text: "Quick", color: .green,
                help: "Selling faster than usual: about \(perDay7) a day over the last 7 days against \(perDay) a day on average over \(lookback) days.", kind: .market))
        case "slow":
            badges.append(PriceBadge(text: "Slow", color: .secondary,
                help: "Selling slower than usual: about \(perDay7) a day over the last 7 days against \(perDay) a day on average over \(lookback) days.", kind: .market))
        default:
            break
        }
        switch spread {
        case "wide":
            badges.append(PriceBadge(text: "Wide", color: .secondary,
                help: "Wide gap between buy and sell orders at \(place) (sell more than double buy), so the price is shaky.", kind: .market))
        case "tight":
            badges.append(PriceBadge(text: "Tight", color: .green,
                help: "Buy and sell orders at \(place) are within 10% of each other – a busy, healthy market.", kind: .market))
        default:
            break
        }
        return badges
    }
}

private func formatRate(_ value: Double) -> String {
    value >= 10 ? value.short : String(format: "%.1f", value)
}

extension Array where Element == PriceBadge {
    var priceOnly: [PriceBadge] { filter { $0.kind == .price } }
    var marketOnly: [PriceBadge] { filter { $0.kind == .market } }
}

/// A row of small capsule badges with tooltips.
struct PriceBadgesView: View {
    let badges: [PriceBadge]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(badges) { badge in
                Text(badge.text)
                    .font(.caption2).fontWeight(.medium)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .foregroundStyle(badge.color)
                    .background(badge.color.opacity(0.15), in: Capsule())
                    .help(badge.help)
            }
        }
    }
}

/// The Price Checks menu – one set of choices for every page that prices things.
struct PriceCheckMenu: View {
    @AppStorage(PriceCheckKey.band) private var band = 50
    @AppStorage(PriceCheckKey.lookbackDays) private var lookbackDays = 30
    @AppStorage(PriceCheckKey.batchRuns) private var batchRuns = 10
    /// Build vs Sell has its own Runs box now, so the menu leaves the batch out by default.
    var showBatch = false

    var body: some View {
        Menu("Price Checks") {
            Picker("Flag prices more than", selection: $band) {
                ForEach([25, 50, 75, 100], id: \.self) { Text("±\($0)% from fair").tag($0) }
            }
            Picker("Fair price from", selection: $lookbackDays) {
                ForEach([7, 14, 30, 60, 90], id: \.self) { Text("Last \($0) days of sales").tag($0) }
            }
            if showBatch {
                Picker("Price a batch of", selection: $batchRuns) {
                    ForEach([1, 5, 10, 20, 50, 100], id: \.self) { Text("\($0) run\($0 == 1 ? "" : "s")").tag($0) }
                }
            }
        }
        .fixedSize()
        .help("Prices are averaged over the best orders for the amount you'd trade, compared with the median of daily sales, and capped when they look inflated. These settings apply on every page.")
    }
}

// MARK: - Key

/// A "?" button that pops up a plain-English key: what each column means on this page,
/// then what every badge means. Makes a screenshot understandable to anyone.
struct PageKeyButton: View {
    /// (column name, what it means) for the page it sits on.
    let columns: [(String, String)]
    @State private var showing = false

    private static let badgeKey: [(String, Color, String)] = [
        ("Inflated", .orange, "Price is well above the fair price – the fair price is used instead."),
        ("Dumped", .purple, "Price is well below the fair price – someone is dumping; the live price is kept."),
        ("No history", .secondary, "No recent sales, so the price can't be checked."),
        ("↑ / ↓", .blue, "Price is trending up / down over the last 7 days."),
        ("Quick", .green, "Selling at least 25% faster than usual (last 7 days vs the average)."),
        ("Slow", .secondary, "Selling at least 25% slower than usual."),
        ("Tight", .green, "Buy and sell orders within 10% – a busy, healthy market."),
        ("Wide", .secondary, "Sell price more than double the buy price – the price is shaky."),
        ("▲ / ▼ n", .orange, "Number of sellers up / down since about a week ago."),
    ]

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .help("What the columns and badges mean")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !columns.isEmpty {
                        Text("Columns").font(.headline)
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                            ForEach(columns.indices, id: \.self) { index in
                                GridRow {
                                    Text(columns[index].0).fontWeight(.semibold)
                                    Text(columns[index].1).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Divider()
                    }
                    Text("Badges").font(.headline)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(Self.badgeKey.indices, id: \.self) { index in
                            let item = Self.badgeKey[index]
                            GridRow {
                                Text(item.0)
                                    .font(.caption2).fontWeight(.medium)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .foregroundStyle(item.1)
                                    .background(item.1.opacity(0.15), in: Capsule())
                                Text(item.2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Text("Hover over any number or badge for the details behind it.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(14)
            }
            .frame(width: 460, height: 440)
        }
    }
}
