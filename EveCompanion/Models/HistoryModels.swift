import SwiftUI

// MARK: - Shared history range

/// The single time range every page uses (picked in the sidebar). 0 = All.
struct HistoryRangePicker: View {
    @AppStorage(HistoryRange.key) private var rangeDays = HistoryRange.defaultDays

    var body: some View {
        Picker(selection: $rangeDays) {
            ForEach(HistoryRange.choices.map { $0.days }, id: \.self) { days in
                Text(HistoryRange.label(days)).tag(days)
            }
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
        }
        .pickerStyle(.menu)
        .help("Time range used on every page (Finances, track record, order results, completed jobs…). History builds up each time you open the app.")
    }
}

// MARK: - Competition trend (order-book snapshots)

struct CompetitionTrend: Decodable {
    let sellOrdersNow: Int
    let sellOrdersBefore: Int
    let sellVolumeNow: Int
    let sellVolumeBefore: Int
    let lowestNow: Double?
    let lowestBefore: Double?
    let days: Double

    var sellersChange: Int { sellOrdersNow - sellOrdersBefore }

    /// "▲3 sellers in 7 days"
    var shortLabel: String {
        let change = sellersChange
        let arrow = change > 0 ? "▲" : (change < 0 ? "▼" : "=")
        return "\(arrow)\(abs(change))"
    }

    var description: String {
        let span = days >= 1 ? "\(Int(days.rounded())) day\(Int(days.rounded()) == 1 ? "" : "s")" : "today"
        var text = "Sellers \(sellOrdersBefore) → \(sellOrdersNow), units listed \(sellVolumeBefore.short) → \(sellVolumeNow.short) over \(span)."
        if let lowestNow, let lowestBefore {
            text += "\nLowest price \(lowestBefore.isk) → \(lowestNow.isk)."
        }
        return text
    }
}

// MARK: - Manufacturing track record (/history/track-record)

struct TrackRecord: Decodable {
    let productTypeId: Int
    let jobs: Int
    let builtUnits: Int
    let buildCost: Double
    let costPerUnit: Double?
    let soldUnits: Int
    let untrackedSold: Int
    let revenue: Double
    let averageSalePrice: Double?
    let fees: Double
    let feeRate: Double
    let costOfSold: Double
    let profit: Double
    let profitPerUnit: Double?
    let inStock: Int
    let inStockCost: Double
    let dataSince: String?
    let rangeLabel: String?
}

// MARK: - Finished orders (/history/order-results)

struct OrderResults: Decodable {
    let rangeLabel: String
    let finished: Int
    let filled: Int
    let partFilled: Int
    let unsold: Int
    let cancelled: Int
    let averageHoursToFill: Double?
    let gotVsListed: Double?
    let checks: Int
    let beatenShare: Double?
    let averageGap: Double?
    let orders: [FinishedOrder]
}

struct FinishedOrder: Decodable, Identifiable {
    let orderId: Int
    let typeId: Int
    let name: String
    let station: String?
    let isBuy: Bool
    let price: Double
    let volumeTotal: Int
    let unitsTraded: Int
    let outcome: String
    let issued: Date
    let finished: Date
    let averageTradePrice: Double?

    var id: Int { orderId }
    var place: String { station ?? "" }
    var side: String { isBuy ? "Buy" : "Sell" }
    var averageTradeSort: Double { averageTradePrice ?? -1 }
    var duration: TimeInterval { finished.timeIntervalSince(issued) }
}

// MARK: - Completed jobs (/history/jobs)

struct CompletedJobs: Decodable {
    let rangeLabel: String
    let jobs: [CompletedJob]
    let monthly: [JobMonth]
}

struct CompletedJob: Decodable, Identifiable {
    let jobId: Int
    let activityId: Int
    let typeId: Int
    let name: String
    let runs: Int
    let cost: Double
    let endDate: Date
    let status: String
    let location: String?
    var id: Int { jobId }
}

struct JobMonth: Decodable, Identifiable {
    let month: String
    let runs: Int
    let jobs: Int
    let cost: Double
    var id: String { month }
}

// MARK: - Net worth over time (/history/net-worth, finances)

struct NetWorthPoint: Decodable, Identifiable {
    let date: String
    let wallet: Double?
    let total: Double?
    var id: String { date }
    var day: Date {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        return parser.date(from: date) ?? .now
    }
}

struct FinanceMonth: Decodable, Identifiable {
    let month: String
    let income: Double
    let spending: Double
    let net: Double
    let mined: Double
    var id: String { month }
    var start: Date {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM"
        parser.timeZone = TimeZone(identifier: "UTC")
        return parser.date(from: month) ?? .now
    }
}
