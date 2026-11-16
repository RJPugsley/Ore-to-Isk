import Foundation

/// Backend `/esi/blueprints` (ESI `/characters/{id}/blueprints/`).
struct Blueprint: Decodable, Identifiable {
    let itemId: Int
    let typeId: Int
    let locationId: Int
    let locationFlag: String
    let materialEfficiency: Int
    let timeEfficiency: Int
    /// -1 = original (BPO), -2 = copy (BPC), >0 = stack of that many originals.
    let quantity: Int
    /// -1 = infinite (originals).
    let runs: Int

    var id: Int { itemId }
    var isCopy: Bool { quantity == -2 }
    var stackSize: Int { quantity > 0 ? quantity : 1 }
}

/// Backend `/esi/industry/jobs` (ESI `/characters/{id}/industry/jobs/`).
struct IndustryJob: Decodable, Identifiable {
    let jobId: Int
    let activityId: Int
    let blueprintId: Int
    let blueprintTypeId: Int
    let blueprintLocationId: Int
    let facilityId: Int
    let outputLocationId: Int
    let productTypeId: Int?
    let runs: Int
    let licensedRuns: Int?
    let cost: Double?
    let duration: Int
    let startDate: Date
    let endDate: Date
    let status: String
    let successfulRuns: Int?

    var id: Int { jobId }

    var activity: IndustryActivity { IndustryActivity(rawValue: activityId) ?? .unknown }

    /// "active" jobs past their end date are ready to deliver.
    var isReady: Bool { status == "ready" || (status == "active" && endDate <= Date()) }

    func progress(at now: Date = Date()) -> Double {
        let total = endDate.timeIntervalSince(startDate)
        guard total > 0 else { return 1 }
        return min(max(now.timeIntervalSince(startDate) / total, 0), 1)
    }
}

enum IndustryActivity: Int, CaseIterable {
    case unknown = 0
    case manufacturing = 1
    case researchTE = 3
    case researchME = 4
    case copying = 5
    case reverseEngineering = 7
    case invention = 8
    case reactions = 9
    case reactions2 = 11

    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .manufacturing: "Manufacturing"
        case .researchTE: "TE Research"
        case .researchME: "ME Research"
        case .copying: "Copying"
        case .reverseEngineering: "Reverse Engineering"
        case .invention: "Invention"
        case .reactions, .reactions2: "Reactions"
        }
    }

    var systemImage: String {
        switch self {
        case .manufacturing: "hammer"
        case .researchTE: "clock.arrow.circlepath"
        case .researchME: "cube"
        case .copying: "doc.on.doc"
        case .invention, .reverseEngineering: "lightbulb"
        case .reactions, .reactions2: "flask"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Backend `/esi/locations` entry.
struct LocationInfo: Decodable {
    let name: String
    let station: String
    let container: String?
}
