import Foundation

// Mine / Sell › Reprocess or Sell (Engine/ReprocessOrSell.swift).

struct ROSPlace: Decodable, Hashable {
    let locationId: Int
    let name: String
    let oreFactor: Double
    let scrapBase: Double
    let taxRate: Double
    let canReprocess: Bool
    /// Someone's structure: rigs / tax can't be read, so they're guessed.
    let estimated: Bool
    let isRefinery: Bool
}

/// One step of the breakdown: the item, what it's worth as it is, and what its outputs are worth.
struct ROSNode: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let quantity: Int
    let unitPrice: Double?
    let check: PriceCheck?
    let asIs: Double?
    let reprocessed: Double?
    let tax: Double
    let yieldRate: Double?
    let portionSize: Int
    let leftover: Int
    /// Why it wasn't broken down: too_small · no_reprocessing · depth (nil = it was, or it can't be).
    let stop: String?
    let outputs: [ROSNode]
    /// reprocess · sell · none
    let choice: String
    let value: Double

    /// Unique among its siblings (each output is a different type).
    var id: Int { typeId }
}

struct ROSRow: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let groupName: String?
    let quantity: Int
    let locationId: Int
    let location: String
    let asIs: Double?
    let reprocessed: Double?
    let bestValue: Double
    /// reprocess · sell · either · nothing
    let verdict: String
    let gain: Double?
    let gainPercent: Double?
    let hub: String
    let place: ROSPlace
    let reprocessedHere: Double?
    let reprocessedRefinery: Double?
    let volumeM3: Double
    let jumpsToRefinery: Int?
    let soldPerDay: Double?
    let check: PriceCheck?
    let tree: ROSNode

    var id: String { "\(typeId)-\(locationId)" }

    // Sort keys (Table needs non-optional values).
    var asIsSort: Double { asIs ?? -1 }
    var reprocessedSort: Double { reprocessed ?? -1 }
    var gainSort: Double { gain ?? -.greatestFiniteMagnitude }
    var soldSort: Double { soldPerDay ?? -1 }
    var verdictSort: Int {
        switch verdict {
        case "reprocess": 0
        case "either": 1
        case "sell": 2
        default: 3
        }
    }
    /// Reprocessed at your refinery, though it sits somewhere else.
    var needsHaul: Bool { place.isRefinery && place.locationId != locationId }
}

struct ROSSummary: Decodable {
    let locationId: Int
    let at: String
    let sellHub: String
    let price: String
    let rows: [ROSRow]
    let totalAsIs: Double
    let totalBest: Double
    let reprocessCount: Int
    let sellCount: Int
    let skippedShips: Int
    var skippedOre: Int? = nil
    let scrapmetalLevel: Int
    let refinery: ROSPlace?
    let noRefinery: Bool
    let priceGaps: Int
    let lookbackDays: Int?
}

struct ROSHub: Decodable, Identifiable {
    let hub: String
    let asIs: Double?
    let reprocessed: Double?
    let value: Double
    let verdict: String
    let place: String

    var id: String { hub }
}

struct ROSItem: Decodable {
    let typeId: Int
    let name: String
    let quantity: Int
    let hub: String
    let place: ROSPlace
    let asIs: Double?
    let reprocessed: Double?
    let bestValue: Double
    let verdict: String
    let tree: ROSNode
    let hubs: [ROSHub]
    let splitValue: Double?
    let scrapmetalLevel: Int
    let lookbackDays: Int?
}
