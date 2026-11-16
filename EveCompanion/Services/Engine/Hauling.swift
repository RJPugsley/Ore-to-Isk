import Foundation

/// Haul › Haul Planner: what's sitting at a station, what it's worth at the hub you sell at,
/// how many trips it takes in your hauler, and which trips carry enough to tempt gankers.
enum Hauling {
    /// Location flags of fitted modules – those aren't cargo.
    private static let fittedPrefixes = ["HiSlot", "MedSlot", "LoSlot", "RigSlot", "SubSystemSlot", "ServiceSlot"]
    private static let notCargo: Set<String> = ["Implant", "Skill", "SkillInTraining", "AutoFit"]

    private static func isFitted(_ flag: String) -> Bool {
        fittedPrefixes.contains { flag.hasPrefix($0) }
    }

    // MARK: Ships

    /// Your assembled ships with a cargo hold of at least `minimum` m³, biggest first:
    /// [{item_id, type_id, type_name, name, location, base_capacity, cargo, skill_name,
    ///   skill_level, bonus_per_level, modules: [String], module_multiplier}].
    /// cargo = hold × (1 + hull bonus × skill level) × every fitted expander / rig.
    static func ships(minimum: Double = 1000) async throws -> [JSONDict] {
        let assets = try await ESI.getAssets()
        let byItem = assets.byItem
        let db = try SDE.connect()

        let singletons = byItem.values.filter { $0.bool("is_singleton") }
        let typeIDs = Array(Set(singletons.compactMap { $0.int("type_id") }))
        guard !typeIDs.isEmpty else { return [] }
        let idList = typeIDs.map(String.init).joined(separator: ",")
        let hulls = (try? db.query("""
            SELECT s.type_id, s.capacity, s.bonus_skill_id, s.bonus_per_level, t.name, k.name AS skill_name
            FROM ship_cargo s JOIN types t ON t.type_id = s.type_id
            LEFT JOIN types k ON k.type_id = s.bonus_skill_id
            WHERE s.type_id IN (\(idList))
            """)) ?? []
        var hullByType: [Int: JSONDict] = [:]
        for h in hulls { if let id = h.int("type_id") { hullByType[id] = h } }
        guard !hullByType.isEmpty else { return [] }

        // Fitted modules per ship, and their cargo multipliers.
        var fittedByShip: [Int: [Int]] = [:]
        for a in byItem.values {
            guard let flag = a.string("location_flag"), isFitted(flag),
                  let ship = a.int("location_id"), let type = a.int("type_id") else { continue }
            fittedByShip[ship, default: []].append(type)
        }
        let moduleTypes = Array(Set(fittedByShip.values.flatMap { $0 }))
        var multiplierByModule: [Int: Double] = [:]
        var moduleNames: [Int: String] = [:]
        if !moduleTypes.isEmpty {
            let list = moduleTypes.map(String.init).joined(separator: ",")
            for r in (try? db.query("SELECT c.type_id, c.multiplier, t.name FROM cargo_modifiers c JOIN types t ON t.type_id = c.type_id WHERE c.type_id IN (\(list))")) ?? [] {
                if let id = r.int("type_id"), let m = r.double("multiplier") {
                    multiplierByModule[id] = m
                    moduleNames[id] = r.string("name") ?? "Module"
                }
            }
        }

        let levels = (try? await Market.skillLevels()) ?? [:]
        let shipsHere = singletons.filter { hullByType[$0.int("type_id") ?? 0] != nil }
        let roots = shipsHere.map { Market.rootLocation($0, byItem) }
        let places = await ESI.resolveLocations(Array(Set(roots)))

        var rows: [JSONDict] = []
        for (ship, root) in zip(shipsHere, roots) {
            guard let itemID = ship.int("item_id"), let typeID = ship.int("type_id"),
                  let hull = hullByType[typeID] else { continue }
            let base = hull.double("capacity") ?? 0
            let perLevel = hull.double("bonus_per_level") ?? 0
            let skillID = hull.int("bonus_skill_id")
            let level = skillID.flatMap { levels[$0] } ?? 0
            var multiplier = 1.0
            var modules: [String] = []
            for module in fittedByShip[itemID] ?? [] {
                if let m = multiplierByModule[module] {
                    multiplier *= m
                    modules.append(moduleNames[module] ?? "Module")
                }
            }
            let cargo = base * (1 + perLevel / 100 * Double(level)) * multiplier
            guard cargo >= minimum else { continue }
            let place = (places[String(root)] as? JSONDict)?.string("station") ?? "Unknown location"
            rows.append([
                "item_id": itemID,
                "type_id": typeID,
                "type_name": hull.string("name") ?? "Ship",
                "name": assets.names[itemID] as Any,
                "location_id": root,
                "location": place,
                "base_capacity": base,
                "cargo": cargo,
                "skill_name": hull.string("skill_name") as Any,
                "skill_level": level,
                "bonus_per_level": perLevel,
                "modules": modules,
                "module_multiplier": multiplier,
            ])
        }
        return rows.sorted { ($0.double("cargo") ?? 0) > ($1.double("cargo") ?? 0) }
    }

    // MARK: Plan

    /// Everything at `start` (incl. containers and ship cargo, not fitted modules or assembled ships),
    /// priced at the `hub`, packed into trips of `cargo` m³ – most ISK per m³ first.
    static func plan(start: Int, hub hubName: String, cargo: Double, excluded: Set<Int>,
                     warnValue: Double) async throws -> JSONDict {
        let assets = try await ESI.getAssets()
        let byItem = assets.byItem
        let db = try SDE.connect()
        let hub = try await Market.hub(hubName)
        let hubLabel = hub.string("name") ?? hubName

        // ---- What's there ----
        struct Pile { var quantity = 0; var singletonVolume = false }
        var piles: [Int: Pile] = [:]
        var skippedShips: [Int: Int] = [:]
        let allTypes = Array(Set(byItem.values.compactMap { $0.int("type_id") }))
        var info: [Int: JSONDict] = [:]
        if !allTypes.isEmpty {
            for r in try db.query("""
                SELECT t.type_id, t.name, t.volume, t.packaged_volume, t.market_group_id, t.category_id,
                       g.name AS group_name
                FROM types t LEFT JOIN groups g ON g.group_id = t.group_id
                WHERE t.type_id IN (\(allTypes.map(String.init).joined(separator: ",")))
                """) {
                if let id = r.int("type_id") { info[id] = r }
            }
        }
        // Items sitting inside something that's fitted or is itself an assembled ship's fitting don't count.
        for a in byItem.values {
            guard let typeID = a.int("type_id") else { continue }
            let flag = a.string("location_flag") ?? ""
            if isFitted(flag) || notCargo.contains(flag) { continue }
            guard Market.rootLocation(a, byItem) == start else { continue }
            let t = info[typeID] ?? [:]
            let singleton = a.bool("is_singleton")
            if singleton && t.int("category_id") == SDE.shipCategory {
                skippedShips[typeID, default: 0] += 1   // assembled ships fly themselves
                continue
            }
            if singleton && (t.string("group_name") ?? "").localizedCaseInsensitiveContains("container") {
                continue   // the container itself – its contents are counted
            }
            var pile = piles[typeID] ?? Pile()
            pile.quantity += a.int("quantity") ?? 1
            if singleton { pile.singletonVolume = true }
            piles[typeID] = pile
        }

        // ---- Prices at the hub ----
        let settings = FairPrice.Settings.current
        let levels = try await Market.skillLevels()
        let standingMap = (try? await Market.standings()) ?? [:]
        let accounting = Double(try IndustryCalc.skillLevel(levels, "Accounting"))
        let salesTax = 0.075 * (1 - 0.11 * accounting)
        let broker = try IndustryCalc.brokerFee(levels, hub, standingMap)

        let marketable = piles.keys.filter { info[$0]?.int("market_group_id") != nil }
        let (books, failed) = try await Market.hubBooksAllowingGaps(hubLabel, marketable)
        let histories = try await concurrentMap(Array(marketable), limit: 6) { id -> (Int, JSONDict?) in
            (id, try? await Market.hubHistory(hubLabel, id, days: settings.lookbackDays))
        }
        var historyByType: [Int: JSONDict] = [:]
        for (id, h) in histories { if let h { historyByType[id] = h } }

        // ---- Rows ----
        struct Row {
            var typeID: Int
            var dict: JSONDict
            var unitM3: Double
            var quantity: Int
            var netEach: Double?
            var included: Bool
            var perM3: Double { guard let netEach, unitM3 > 0 else { return -1 }; return netEach / unitM3 }
        }
        var rows: [Row] = []
        for (typeID, pile) in piles {
            let t = info[typeID] ?? [:]
            let unitM3: Double = pile.singletonVolume
                ? (t.double("volume") ?? 0)
                : (t.double("packaged_volume") ?? t.double("volume") ?? 0)
            let quantity = pile.quantity
            let totalM3 = unitM3 * Double(quantity)
            let isMarketable = t.int("market_group_id") != nil
            var check: JSONDict?
            var spread: String?
            var sellEach: Double?
            var instantEach: Double?
            if isMarketable {
                let book = books[typeID] ?? [:]
                let live: Double? = FairPrice.sellDepthPrice(book, quantity: quantity)
                let checked = FairPrice.check(live: live, history: historyByType[typeID], quantity: quantity, settings: settings)
                check = checked
                spread = FairPrice.spread(book)
                // No sell orders at all: fall back to the fair price so the haul still has a value.
                sellEach = checked.double("used") ?? checked.double("fair")
                instantEach = FairPrice.buyDepthPrice(book, quantity: quantity)
            }
            let netEach: Double? = sellEach.map { $0 * (1 - broker - salesTax) }
            let value: Double? = netEach.map { $0 * Double(quantity) }
            let instantValue: Double? = instantEach.map { $0 * Double(quantity) * (1 - salesTax) }
            let perM3: Double? = (netEach != nil && unitM3 > 0) ? netEach! / unitM3 : nil
            let dict: JSONDict = [
                "type_id": typeID,
                "name": t.string("name") ?? "Type \(typeID)",
                "group": t.string("group_name") as Any,
                "quantity": quantity,
                "unit_m3": unitM3,
                "total_m3": totalM3,
                "marketable": isMarketable,
                "sell_each": sellEach as Any,
                "value": value as Any,
                "instant_value": instantValue as Any,
                "isk_per_m3": perM3 as Any,
                "check": check as Any,
                "spread": spread as Any,
                "sold_per_day": (historyByType[typeID]?.double("sold_per_day")) as Any,
                "included": !excluded.contains(typeID),
                "assembled": pile.singletonVolume,
            ]
            rows.append(Row(typeID: typeID, dict: dict, unitM3: unitM3, quantity: quantity,
                            netEach: netEach, included: !excluded.contains(typeID)))
        }

        // ---- Trips: most ISK per m³ first, stacks split where they have to be ----
        var trips: [(m3: Double, value: Double, items: Int)] = []
        var tripsByType: [Int: [Int]] = [:]
        var tooBig: Set<Int> = []
        let capacity = max(cargo, 0)
        let order = rows.filter(\.included).sorted { $0.perM3 > $1.perM3 }
        if capacity > 0 {
            for row in order {
                var left = row.quantity
                if row.unitM3 > capacity { tooBig.insert(row.typeID); continue }
                while left > 0 {
                    if trips.isEmpty { trips.append((0, 0, 0)) }
                    var index = trips.count - 1
                    var free = capacity - trips[index].m3
                    var fit = row.unitM3 > 0 ? Int((free / row.unitM3 + 1e-9).rounded(.down)) : left
                    if fit <= 0 {
                        trips.append((0, 0, 0))
                        index += 1
                        free = capacity
                        fit = row.unitM3 > 0 ? Int((free / row.unitM3 + 1e-9).rounded(.down)) : left
                    }
                    let take = min(fit, left)
                    trips[index].m3 += Double(take) * row.unitM3
                    trips[index].value += Double(take) * (row.netEach ?? 0)
                    trips[index].items += 1
                    if tripsByType[row.typeID]?.last != index + 1 { tripsByType[row.typeID, default: []].append(index + 1) }
                    left -= take
                }
            }
        }

        let items: [JSONDict] = rows.map { row in
            var d = row.dict
            d["trips"] = tripsByType[row.typeID] ?? []
            d["too_big"] = tooBig.contains(row.typeID)
            return d
        }.sorted { ($0.double("isk_per_m3") ?? -1) > ($1.double("isk_per_m3") ?? -1) }

        let included = rows.filter(\.included)
        let totalM3 = included.reduce(0.0) { $0 + $1.unitM3 * Double($1.quantity) }
        let totalValue = included.reduce(0.0) { $0 + ($1.netEach ?? 0) * Double($1.quantity) }
        let tripRows: [JSONDict] = trips.enumerated().map { index, trip in
            [
                "trip": index + 1,
                "m3": trip.m3,
                "value": trip.value,
                "items": trip.items,
                "risky": warnValue > 0 && trip.value > warnValue,
            ]
        }

        // ---- Route (safest, high-sec where possible) ----
        let startName = (await ESI.resolveLocations([start])[String(start)] as? JSONDict)?.string("station") ?? "Unknown"
        let route = await route(from: start, toSystem: hub.int("system_id"))

        var skipped: [JSONDict] = []
        for (typeID, count) in skippedShips {
            skipped.append(["name": info[typeID]?.string("name") ?? "Ship", "count": count])
        }

        return [
            "start_location": start,
            "start_name": startName,
            "hub": hubLabel,
            "hub_station": hub.string("station_name") ?? hubLabel,
            "cargo": capacity,
            "broker_fee": broker,
            "sales_tax": salesTax,
            "lookback_days": settings.lookbackDays,
            "warn_value": warnValue,
            "items": items,
            "trips": tripRows,
            "total_m3": totalM3,
            "total_value": totalValue,
            "too_big": tooBig.count,
            "price_gaps": failed.count,
            "assembled_ships": skipped,
            "route": route as Any,
        ]
    }

    // MARK: Route

    /// The game's "prefer safer" route from the location's system to the hub's:
    /// {jumps, lowest_security, systems: [{system_id, name, security}]}, or nil if it can't be found.
    static func route(from location: Int, toSystem destination: Int?) async -> JSONDict? {
        guard let destination, let origin = await systemOf(location) else { return nil }
        let ids: [Int] = (try? await Routes.esiRoute(origin, destination, flag: "secure", avoid: [])) ?? []
        guard !ids.isEmpty, let db = try? SDE.connect() else { return nil }
        var byID: [Int: JSONDict] = [:]
        for r in (try? db.query("SELECT system_id, name, security FROM solar_systems WHERE system_id IN (\(ids.map(String.init).joined(separator: ",")))")) ?? [] {
            if let id = r.int("system_id") { byID[id] = r }
        }
        let systems: [JSONDict] = ids.map { id in
            ["system_id": id, "name": byID[id]?.string("name") ?? String(id), "security": byID[id]?.double("security") as Any]
        }
        let lowest = systems.compactMap { $0.double("security") }.min()
        return ["jumps": max(ids.count - 1, 0), "lowest_security": lowest as Any, "systems": systems]
    }

    /// Solar system of a station, player structure (needs docking access) or system id.
    static func systemOf(_ location: Int) async -> Int? {
        if ESI.isSystem(location) { return location }
        if ESI.isStation(location) {
            // The static data knows every NPC station's system – no need to ask EVE.
            if let row = (try? SDE.connect().query("SELECT system_id FROM npc_stations WHERE station_id = ?", [location]))?.first,
               let system = row.int("system_id") {
                return system
            }
            let station: Any? = try? await cached("station:\(location)", ttl: 7 * 24 * 3600) { () async throws -> Any in
                try await ESI.get("universe/stations/\(location)/", auth: false)
            }
            return (station as? JSONDict)?.int("system_id")
        }
        // A structure the app already knows (you've docked there, or EVE described it before).
        if let known = await HistoryStore.shared.structureRow(location), let system = known.int("system_id"), system != 0 {
            return system
        }
        let structure: Any? = try? await cached("structure:\(location)", ttl: 24 * 3600) { () async throws -> Any in
            try await ESI.get("universe/structures/\(location)/")
        }
        if let info = structure as? JSONDict, let system = info.int("solar_system_id") {
            await HistoryStore.shared.saveStructure(location, name: info.string("name"), system: system, type: info.int("type_id"))
            return system
        }
        // Last resort (user's idea): station and structure names start with their system's name –
        // "Jita IV - Moon 4 - Caldari Navy Assembly Plant" is in Jita.
        let name = await ESI.placeName(location)
        if let system = systemFromName(name) {
            await HistoryStore.shared.saveStructure(location, name: name, system: system, type: nil)
            return system
        }
        return nil
    }

    /// The system a station / structure name starts with (the longest system name that fits, followed by a space).
    static func systemFromName(_ name: String) -> Int? {
        guard !name.isEmpty, !name.hasPrefix("Structure "),
              let first = name.split(separator: " ").first.map(String.init),
              let rows = try? SDE.connect().query(
                "SELECT system_id, name FROM solar_systems WHERE name LIKE ? ORDER BY length(name) DESC", ["\(first)%"])
        else { return nil }
        for row in rows {
            guard let systemName = row.string("name") else { continue }
            if name == systemName || name.hasPrefix(systemName + " ") { return row.int("system_id") }
        }
        return nil
    }
}
