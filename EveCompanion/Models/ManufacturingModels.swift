import Foundation

// Decoded with .convertFromSnakeCase (see BackendClient.decoder).

struct SDEStatus: Decodable, Equatable {
    let state: String          // missing | downloading | importing | ready | error
    let message: String?
    let build: String?

    var isReady: Bool { state == "ready" }
}

/// A manufacturable product (from /industry/products or /industry/my-products).
struct ProductOption: Decodable, Identifiable, Hashable {
    let blueprintTypeId: Int
    let productTypeId: Int
    let productName: String
    let groupName: String?
    let metaGroupId: Int?
    // Only for blueprints you own:
    let me: Int?
    let te: Int?
    let isCopy: Bool?
    let runs: Int?
    let count: Int?

    var id: Int { blueprintTypeId }
    var isOwned: Bool { me != nil }
}

struct SolarSystem: Decodable, Identifiable, Hashable {
    let systemId: Int
    let name: String
    let security: Double?
    let regionId: Int?
    let regionName: String?

    var id: Int { systemId }
    var securityLabel: String {
        guard let security else { return "" }
        return String(format: "%.1f", (security * 10).rounded() / 10)
    }
}

/// Backend /reprocessing/summary
struct ReproSummary: Decodable {
    let locationId: Int
    let hub: String
    let price: String
    let oreFactor: Double
    let iceFactor: Double
    let reprocessingLevel: Int
    let efficiencyLevel: Int
    let ores: [ReproOre]
    let minerals: [ReproOutput]
    let totalValueAsOre: Double
    let totalValueAsMinerals: Double
    let totalTax: Double
    let lookbackDays: Int?
}

struct ReproOre: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let groupName: String?
    let quantity: Int
    let leftover: Int
    let portionSize: Int?
    let skill: String?
    let skillLevel: Int
    let yieldRate: Double
    let outputs: [ReproOutput]
    let mineralsValue: Double
    let tax: Double
    let valueAsMinerals: Double
    let oreUnitPrice: Double
    let valueAsOre: Double
    let better: String
    /// Fair-price check on the ore price (FairPrice.swift).
    let oreCheck: PriceCheck?

    var id: Int { typeId }
}

extension ReproOre {
    /// Fewer units than one reprocessing batch – gives nothing yet.
    var tooSmall: Bool { quantity < (portionSize ?? 1) }

    // Sort keys for the Reprocessing table.
    /// Main output first ("Tritanium, Pyerite…").
    var outputsSort: String { outputs.map(\.name).joined(separator: ", ") }
    /// Minerals value; stacks too small to reprocess sort last.
    var mineralsValueSort: Double { tooSmall ? -.infinity : valueAsMinerals }
    /// How much better reprocessing is than selling the ore (negative = sell ore).
    var bestSort: Double { tooSmall ? -.infinity : valueAsMinerals - valueAsOre }
}

/// One ore in the game-wide ore list (/reprocessing/ores).
struct OreCatalogEntry: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let groupName: String?
    let compressed: Bool
    let skill: String?
    let outputs: [String]
    /// Base amount of each output per portion (same order as outputs), as the game shows it.
    let outputQuantities: [Int]?
    let portionSize: Int?
    /// Your reprocessing yield at the refinery (refinery bonus × your skills), and what one portion gives you.
    let yield: Double?
    let yourQuantities: [Int]?
    /// Where it's found (from Config/ore_locations.json).
    let security: Double?
    let space: String?
    let locationNote: String?

    var id: Int { typeId }
    var family: String { groupName ?? "" }
}

struct ReproOutput: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let quantity: Int
    let unitPrice: Double
    let value: Double
    /// Reprocessing tax on this output (per-ore breakdown only).
    let tax: Double?
    /// Fair-price check (combined minerals list) / its status (per-ore breakdown).
    let check: PriceCheck?
    let priceStatus: String?

    var priceFlagged: Bool {
        let status = check?.status ?? priceStatus
        return status == "inflated" || status == "dumped"
    }

    var id: Int { typeId }

    // Sort keys for the Reprocessing tables.
    var taxSort: Double { tax ?? 0 }
    var net: Double { value - (tax ?? 0) }
}

/// A station / structure where you keep things (from /industry/stock-locations).
struct StockLocation: Decodable, Identifiable, Hashable {
    let locationId: Int
    let name: String
    let items: Int

    var id: Int { locationId }
}

struct CalcResult: Decodable {
    let blueprintTypeId: Int
    let blueprintName: String
    let productTypeId: Int
    let productName: String
    let groupName: String?
    let runs: Int
    let productQuantity: Int
    let me: Int
    let te: Int
    let materials: [CalcMaterial]
    let materialCost: Double
    let cashCost: Double
    let materialHub: String
    let materialPrice: String
    let time: CalcTime
    let job: CalcJob
    let totalCost: Double
    let totalCashCost: Double
    let hubs: [HubResult]
    let bestHub: String?
    let accountingLevel: Int
    let warnings: [String]
}

struct CalcMaterial: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let baseQuantity: Int
    let required: Int
    let owned: Int
    let fromOre: Int?
    let toBuy: Int
    let unitPrice: Double
    let totalValue: Double
    let buyCost: Double
    let priceSource: String
    let volumeM3: Double

    var id: Int { typeId }
}

struct CalcTime: Decodable {
    let baseSeconds: Double
    let seconds: Double
    let industryLevel: Int
    let advancedIndustryLevel: Int
    let modifier: Double
}

struct CalcJob: Decodable {
    let system: SolarSystem?
    let costIndex: Double
    let estimatedItemValue: Double
    let facilityTax: Double
    let sccSurcharge: Double
    let structure: String
    let feeRate: Double
    let fee: Double
}

struct HubResult: Decodable, Identifiable {
    let hub: String
    let stationName: String
    let brokerFee: Double
    let salesTax: Double
    let sellOrder: SaleOutcome?
    let instant: SaleOutcome?
    let sellOrders: Int
    let sellVolume: Int
    let buyOrders: Int
    let buyVolume: Int
    /// Sellers / units listed now vs about a week ago (from stored snapshots).
    let trend: CompetitionTrend?
    // Fair-price check (FairPrice.swift)
    let lowestSell: Double?
    let bestBuy: Double?
    let sellCheck: PriceCheck?
    let buyCheck: PriceCheck?
    let spread: String?
    let lookbackDays: Int?

    var id: String { hub }
}

struct SaleOutcome: Decodable {
    let unitPrice: Double
    let gross: Double
    let fees: Double
    let net: Double
    let profit: Double
    let profitCash: Double
    let margin: Double?
    let iskPerHour: Double?
    let cashMargin: Double?
    let cashIskPerHour: Double?
}

/// Where you build and how materials are priced. Stored in UserDefaults.
enum StructureKind: String, CaseIterable, Identifiable {
    case npc, raitaru, azbel, sotiyo
    var id: Self { self }
    var title: String {
        switch self {
        case .npc: "NPC Station"
        case .raitaru: "Raitaru"
        case .azbel: "Azbel"
        case .sotiyo: "Sotiyo"
        }
    }
}

enum TradeHub: String, CaseIterable, Identifiable {
    case Jita, Amarr, Dodixie, Rens, Hek
    var id: Self { self }
}

/// How every number in the app is shown (user's rule, 15 Nov 2026): at most 5 digits,
/// decimals included, then a letter. No "ISK" – it's the only currency.
///   4.60 · 3.9012 · 102.19 · 99999 (plain; whole numbers have no decimals, others keep at least 2)
///   123.46k                         (100,000+)
///   1.2346m · 12.346m · 123.46m     (1,000,000+)
///   1.2346b · 12.346b               (1,000,000,000+)
enum NumberStyle {
    static let maxDigits = 5

    static func short(_ number: Double) -> String {
        guard number.isFinite else { return "–" }
        let sign = number < 0 ? "-" : ""
        let value = abs(number)

        // Plain numbers: everything that fits in 5 digits once rounded.
        let plain = fit(value)
        if plain.value < 100_000 {
            return sign + trimZeros(plain.text)
        }

        // Letters: k from 100,000, m from a million, b from a billion.
        let units: [(Double, String)] = [(1_000, "k"), (1_000_000, "m"), (1_000_000_000, "b")]
        var index = value < 1_000_000 ? 0 : (value < 1_000_000_000 ? 1 : 2)
        while true {
            let (size, letter) = units[index]
            let scaled = fit(value / size)
            // Rounding can push 999.996k up to 1000.0k – show that as the next letter instead.
            if scaled.value >= 1_000, index < units.count - 1 {
                index += 1
                continue
            }
            return sign + scaled.text + letter
        }
    }

    /// Round to fill 5 digits: as many decimals as the whole part leaves room for.
    private static func fit(_ value: Double) -> (value: Double, text: String) {
        var decimals = max(0, maxDigits - wholeDigits(value))
        while true {
            let factor = pow(10.0, Double(decimals))
            let rounded = (value * factor).rounded() / factor
            if decimals > 0 && wholeDigits(rounded) + decimals > maxDigits {
                decimals -= 1   // 9.99996 → 10.000, one digit too many – drop a decimal
                continue
            }
            return (rounded, String(format: "%.\(decimals)f", rounded))
        }
    }

    private static func wholeDigits(_ value: Double) -> Int {
        value < 1 ? 1 : Int(log10(value).rounded(.down)) + 1
    }

    /// Whole numbers lose their decimals (5.0000 → 5). Otherwise zeros are dropped only
    /// past the second decimal, so prices keep their pence: 4.6000 → 4.60, 3.9010 → 3.901.
    private static func trimZeros(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        let fraction = text[text.index(after: dot)...]
        if fraction.allSatisfy({ $0 == "0" }) { return String(text[..<dot]) }
        var trimmed = text
        while trimmed.hasSuffix("0"), trimmed.distance(from: dot, to: trimmed.endIndex) > 3 {
            trimmed.removeLast()
        }
        return trimmed
    }
}

extension Double {
    /// The app-wide number style: 4.5 · 99999 · 123.46k · 1.2346m · 1.2346b
    var short: String { NumberStyle.short(self) }

    /// ISK amounts use the same style – no "ISK" suffix (it's the only currency).
    var iskShort: String { short }
    var isk: String { short }

    /// Every digit, for tooltips where the exact price matters (undercutting orders).
    var iskExact: String {
        formatted(.number.precision(.fractionLength(2)))
    }

    var percent: String {
        (self).formatted(.percent.precision(.fractionLength(2)))
    }
}

extension TimeInterval {
    /// 33792 → "9h 23m"
    var durationLabel: String {
        let total = Int(self.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}
