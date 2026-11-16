import Foundation

// All models decode with `.convertFromSnakeCase`, so `skill_id` → `skillId`.

struct CharacterIDResponse: Decodable {
    let characterId: Int
}

/// Public character sheet from ESI `/characters/{id}/`.
struct CharacterInfo: Decodable {
    let name: String
    let corporationId: Int
    let allianceId: Int?
    let birthday: Date
    let securityStatus: Double?
}

/// Backend `/esi/skills`.
struct SkillsResponse: Decodable {
    let skills: [Skill]
    let totalSp: Int
    let unallocatedSp: Int?
}

struct Skill: Decodable, Identifiable {
    let skillId: Int
    let activeSkillLevel: Int
    let trainedSkillLevel: Int
    let skillpointsInSkill: Int

    var id: Int { skillId }
}

/// Backend `/esi/skillqueue` entry.
struct SkillQueueEntry: Decodable, Identifiable {
    let skillId: Int
    let finishedLevel: Int
    let queuePosition: Int
    let startDate: Date?
    let finishDate: Date?
    let trainingStartSp: Int?
    let levelStartSp: Int?
    let levelEndSp: Int?

    var id: Int { queuePosition }

    /// Time-based progress (0...1) for the skill currently training.
    func progress(at now: Date = Date()) -> Double? {
        guard let start = startDate, let finish = finishDate, finish > start else { return nil }
        let value = now.timeIntervalSince(start) / finish.timeIntervalSince(start)
        return min(max(value, 0), 1)
    }
}

/// ESI `/universe/names/` result.
struct ResolvedName: Decodable {
    let id: Int
    let name: String
    let category: String
}

/// FastAPI error body: `{"detail": "..."}`.
struct APIErrorBody: Decodable {
    let detail: String
}

extension Int {
    /// The app-wide number style: 9999 · 10.34k · 1.234m · 1.234b
    var short: String { NumberStyle.short(Double(self)) }

    /// 1 → "I", 5 → "V". Used for skill levels.
    var roman: String {
        ["0", "I", "II", "III", "IV", "V"].indices.contains(self)
            ? ["0", "I", "II", "III", "IV", "V"][self]
            : String(self)
    }
}
