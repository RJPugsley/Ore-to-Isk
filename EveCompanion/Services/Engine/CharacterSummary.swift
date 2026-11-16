import Foundation

/// Originally `character_summary.py`: who you are and where you are right now.
/// A part whose ESI scope hasn't been granted comes back nil and its scope is listed in
/// "missing_scopes".
enum CharacterSummaryEngine {
    static let scopes = [
        "wallet": "esi-wallet.read_character_wallet.v1",
        "home": "esi-clones.read_clones.v1",
        "location": "esi-location.read_location.v1",
        "ship": "esi-location.read_ship_type.v1",
    ]

    /// "4 years, 2 months"
    static func age(_ birthday: String) -> String? {
        guard let born = ISODate.parse(birthday) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let b = calendar.dateComponents([.year, .month, .day], from: born)
        let n = calendar.dateComponents([.year, .month, .day], from: Date())
        var months = (n.year! - b.year!) * 12 + (n.month! - b.month!)
        if n.day! < b.day! { months -= 1 }
        let years = max(months, 0) / 12
        let rest = max(months, 0) % 12
        var parts: [String] = []
        if years > 0 { parts.append("\(years) year\(years != 1 ? "s" : "")") }
        if rest > 0 || years == 0 { parts.append("\(rest) month\(rest != 1 ? "s" : "")") }
        return parts.joined(separator: ", ")
    }

    private static func system(_ systemID: Int) async -> JSONDict {
        let row = (try? SDE.system(systemID)) ?? nil
        var name = row?.string("name")
        if name == nil {
            name = await ESI.universeNames([systemID])[systemID] ?? String(systemID)
        }
        return [
            "system_id": systemID,
            "system": name as Any,
            "security": row?.double("security") as Any,
            "region": row?.string("region_name") as Any,
        ]
    }

    /// guarded(part, loader): 401/403 → None + missing scope; anything else is raised.
    private static func guarded(_ part: String, missing: inout [String], _ load: () async throws -> Any?) async throws -> Any? {
        do {
            return try await load()
        } catch let error as ESIError where error.isPermissionDenied {
            missing.append(scopes[part]!)
            return nil
        }
    }

    static func summary() async throws -> JSONDict {
        let cid = try await EveAuth.shared.characterID()
        var missing: [String] = []

        guard let pub = try await ESI.get("characters/\(cid)/", auth: false) as? JSONDict,
              let corporationID = pub.int("corporation_id") else {
            throw RouteError(status: 500, detail: "Unexpected character data from ESI")
        }
        let allianceID = pub.int("alliance_id")
        let names = await ESI.universeNames([corporationID] + (allianceID.map { [$0] } ?? []))

        let wallet = try await guarded("wallet", missing: &missing) {
            try await ESI.get("characters/\(cid)/wallet/")
        }

        let home = try await guarded("home", missing: &missing) { () async throws -> Any? in
            let clones = try await ESI.get("characters/\(cid)/clones/") as? JSONDict
            guard let loc = clones?.dict("home_location")?.int("location_id") else { return nil }
            return ["location_id": loc, "name": await ESI.placeName(loc)] as JSONDict
        }

        let location = try await guarded("location", missing: &missing) { () async throws -> Any? in
            guard let loc = try await ESI.get("characters/\(cid)/location/") as? JSONDict,
                  let systemID = loc.int("solar_system_id") else { return nil }
            var result = await system(systemID)
            if let dockedAt = loc.int("station_id") ?? loc.int("structure_id") {
                result["docked_at"] = await ESI.placeName(dockedAt)
                result["docked_id"] = dockedAt
            } else {
                result["docked_at"] = NSNull()
            }
            return result
        }

        let ship = try await guarded("ship", missing: &missing) { () async throws -> Any? in
            guard let data = try await ESI.get("characters/\(cid)/ship/") as? JSONDict,
                  let typeID = data.int("ship_type_id") else { return nil }
            let typeName = (try? SDE.typeNames([typeID]))?[typeID]
            return ["name": data.string("ship_name") as Any, "type_id": typeID, "type_name": typeName as Any] as JSONDict
        }

        return [
            "character_id": cid,
            "name": pub.string("name") as Any,
            "corporation": names[corporationID] as Any,
            "alliance": allianceID.flatMap { names[$0] } as Any,
            "security_status": pub.double("security_status") as Any,
            "birthday": pub.string("birthday") as Any,
            "playing_for": pub.string("birthday").flatMap(age) as Any,
            "wallet": wallet as Any,
            "home_station": home as Any,
            "location": location as Any,
            "ship": ship as Any,
            "missing_scopes": missing,
        ]
    }
}
