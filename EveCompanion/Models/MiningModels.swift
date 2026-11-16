import Foundation

// MARK: - Mining Ledger (/mining/ledger)

struct MiningLedger: Decodable {
    let rangeLabel: String
    let historySince: String?
    let hub: String
    let totalUnits: Int
    let totalM3: Double
    let totalValue: Double
    let daysMined: Int
    let daily: [MiningDay]
    let byOre: [MinedOre]
    let bySystem: [MinedSystem]
    let entries: [MiningEntry]
}

struct MiningDay: Decodable, Identifiable {
    let date: String
    let units: Int
    let m3: Double
    let value: Double
    var id: String { date }
    var day: Date {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        return parser.date(from: date) ?? .now
    }
}

struct MinedOre: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let units: Int
    let m3: Double
    let value: Double
    let unitPrice: Double
    let share: Double
    var id: Int { typeId }
}

struct MinedSystem: Decodable, Identifiable {
    let systemId: Int
    let name: String
    let security: Double?
    let units: Int
    let value: Double
    var id: Int { systemId }
    var securitySort: Double { security ?? -1 }
}

struct MiningEntry: Decodable, Identifiable {
    let date: String
    let typeId: Int
    let name: String
    let systemId: Int
    let system: String?
    let units: Int
    let m3: Double
    let value: Double
    var id: String { "\(date)-\(typeId)-\(systemId)" }
    var place: String { system ?? "" }
}

// MARK: - Build Planner (/build/plan)

struct BuildPlan: Decodable {
    let items: [PlanItemResult]
    let ores: [PlannedOre]
    let minerals: [PlannedMineral]
    let otherMaterials: [OtherMaterial]
    /// Components you'd build yourself first (broken down into their own materials).
    let buildFirst: [BuildFirstItem]?
    /// Estimated costs: buy list at the hub's sell price, minerals to mine at its buy price.
    let buyTotal: Double?
    let mineralsTotal: Double?
    let ownedComponentBlueprints: Int?
    let priceHub: String?
    let totalM3: Double
    let totalUnits: Int
    let candidates: Int
    let highsecOnly: Bool
    let bands: String?
    let warnings: [String]
}

struct PlanItemResult: Decodable, Identifiable {
    let blueprintTypeId: Int
    let productTypeId: Int
    let productName: String
    let runs: Int
    let units: Int
    let me: Int
    var id: Int { blueprintTypeId }
}

struct PlannedOre: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let family: String
    let batches: Int
    let units: Int
    let m3: Double
    let yield: Double
    let space: String?
    let security: Double?
    let gives: [PlannedGive]
    /// Standard, II-Grade, III-Grade – each on its own gives the same minerals.
    let variants: [OreVariant]?
    var id: Int { typeId }

    func variant(_ grade: String) -> OreVariant? { variants?.first { $0.grade == grade } }
    var standardUnits: Int { units }
    var gradeIIUnits: Int { variant("II-Grade")?.units ?? 0 }
    var gradeIIIUnits: Int { variant("III-Grade")?.units ?? 0 }

    var givesText: String { gives.map { "\($0.quantity.short) \($0.name)" }.joined(separator: ", ") }
}

struct OreVariant: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let grade: String
    let batches: Int
    let units: Int
    let m3: Double
    let gives: [PlannedGive]
    var id: Int { typeId }
}

struct PlannedGive: Decodable {
    let typeId: Int
    let name: String
    let quantity: Int
}

struct PlannedMineral: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let needed: Int
    let have: Int
    let toMine: Int
    let planGives: Int
    let spare: Int
    let unitPrice: Double?
    let value: Double?
    var id: Int { typeId }
    var valueSort: Double { value ?? 0 }
}

struct BuildFirstItem: Decodable, Identifiable {
    let typeId: Int
    let blueprintTypeId: Int
    let name: String
    let needed: Int
    let have: Int
    let toBuild: Int
    let runs: Int
    let me: Int
    let owned: Bool
    var id: Int { typeId }
    var ownedSort: Int { owned ? 1 : 0 }
}

struct OtherMaterial: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let needed: Int
    let have: Int
    let toGet: Int
    /// reaction · planetary · moon · salvage · buy
    let source: String?
    let unitPrice: Double?
    let value: Double?
    var id: Int { typeId }
    var valueSort: Double { value ?? 0 }
    var priceSort: Double { unitPrice ?? 0 }

    static let sourceOrder = ["reaction", "planetary", "moon", "salvage", "buy"]

    static func sourceTitle(_ source: String) -> String {
        switch source {
        case "reaction": return "Reactions – made from moon materials at a refinery"
        case "planetary": return "Planetary Industry – made on planets"
        case "moon": return "Moon Materials – from moon ore"
        case "salvage": return "Salvage – from wrecks"
        default: return "Buy – can't be mined or made"
        }
    }
}
