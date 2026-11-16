import Foundation

/// Originally `reprocessing.py` – ore / ice reprocessing at your refinery.
///
///     yield = refinery_factor * (1 + 3% Reprocessing) * (1 + 2% Reprocessing Efficiency)
///                             * (1 + 2% ore-specific processing skill)
/// Output per mineral = floor(batches * base quantity * yield), batches = units // portion size.
enum Reprocessing {
    /// Ore family (SDE group name) → processing skill.
    static let familySkills: [String: String] = {
        var map: [String: String] = [:]
        for g in ["Veldspar", "Scordite", "Pyroxeres", "Plagioclase", "Mordunium"] { map[g] = "Simple Ore Processing" }
        for g in ["Omber", "Kernite", "Jaspet", "Hemorphite", "Hedbergite", "Ytirium", "Griemeer", "Nocxite"] {
            map[g] = "Coherent Ore Processing"
        }
        for g in ["Dark Ochre", "Gneiss", "Crokite", "Kylixium"] { map[g] = "Variegated Ore Processing" }
        for g in ["Bistot", "Arkonor", "Eifyrium", "Ducinium", "Spodumain", "Hezorime", "Ueganite"] {
            map[g] = "Complex Ore Processing"
        }
        map["Mercoxit"] = "Mercoxit Ore Processing"
        for g in ["Bezdnacine", "Rakovene", "Talassonite"] { map[g] = "Abyssal Ore Processing" }
        // Newer anomaly ores – best guess.
        for g in ["Kangite", "Moissanite", "Mutanite", "Polycrase", "Raspite"] { map[g] = "Erratic Ore Processing" }
        map["Ice"] = "Ice Processing"
        return map
    }()

    static let asteroidCategory = 25

    static func familySkill(_ groupName: String?) -> String? {
        guard let groupName else { return nil }
        if groupName.hasSuffix(" Moon Asteroids") {
            return groupName.replacingOccurrences(of: " Asteroids", with: " Ore Processing") // Rare Moon Ore Processing
        }
        return familySkills[groupName]
    }

    /// Your level in a skill by name (0 if unknown / untrained).
    static func level(_ levels: [Int: Int], _ skillName: String?) throws -> Int {
        guard let skillName, !skillName.isEmpty, let skill = try SDE.skillID(skillName) else { return 0 }
        return levels[skill] ?? 0
    }

    static func skillFactor(_ levels: [Int: Int], _ specificSkill: String?) throws -> Double {
        let reprocessing = Double(try level(levels, "Reprocessing"))
        let efficiency = Double(try level(levels, "Reprocessing Efficiency"))
        let specific = Double(try level(levels, specificSkill))
        return (1 + 0.03 * reprocessing) * (1 + 0.02 * efficiency) * (1 + 0.02 * specific)
    }

    /// Refinery calibration, from query parameters.
    struct Settings {
        var oreYield: Double? = nil                   // % shown in game for the reference ore
        var oreSkill: String = "Coherent Ore Processing"
        var iceYield: Double? = nil                   // % shown in game for ice
        var tax: Double = 1.0                         // refinery tax %, applied to output value

        func factors(_ levels: [Int: Int]) throws -> (ore: Double, ice: Double) {
            var ore = 0.5
            if let oreYield, oreYield != 0 {
                let factor = try Reprocessing.skillFactor(levels, oreSkill)
                ore = (oreYield / 100) / factor
            }
            var ice = ore
            if let iceYield, iceYield != 0 {
                let factor = try Reprocessing.skillFactor(levels, "Ice Processing")
                ice = (iceYield / 100) / factor
            }
            return (ore, ice)
        }
    }

    /// Processing skill for an ore: CCP's data first, the family table as a fallback.
    static func skillFor(_ typeID: Int, _ groupName: String?, _ dogmaSkills: [Int: String]) -> String? {
        dogmaSkills[typeID] ?? familySkill(groupName)
    }

    static func yieldFor(_ groupName: String?, _ levels: [Int: Int], _ oreFactor: Double, _ iceFactor: Double,
                         skill: String? = nil) throws -> (rate: Double, skill: String?) {
        let skill = skill ?? familySkill(groupName)
        let factor = (groupName == "Ice" || skill == "Ice Processing") ? iceFactor : oreFactor
        let skills = try skillFactor(levels, skill)
        return (min(factor * skills, 1.0), skill)
    }

    static func portionSize(_ typeInfo: JSONDict) -> Int {
        max(1, typeInfo.int("portion_size") ?? 1)
    }

    /// [(material_type_id, quantity)] produced by reprocessing `quantity` units (material order kept).
    static func reprocess(_ typeInfo: JSONDict, _ quantity: Int, _ yieldRate: Double) -> [(Int, Int)] {
        let batches = quantity / portionSize(typeInfo)
        return typeInfo.dicts("materials").map { m in
            (m.int("material_type_id") ?? 0, Int((Double(batches) * Double(m.int("quantity") ?? 0) * yieldRate).rounded(.down)))
        }
    }

    /// {type_id: quantity} of ore / ice you own at a location (incl. containers).
    static func oresAt(_ locationID: Int) async throws -> [Int: Int] {
        let owned = try await Market.ownedQuantities(locationID)
        let info = try SDE.typesInfo(owned.keys)
        return owned.filter { typeID, _ in
            guard let t = info[typeID] else { return false }
            return t.int("category_id") == asteroidCategory && !t.dicts("materials").isEmpty
        }
    }

    /// Total minerals you'd get reprocessing all ore at `locationID`.
    static func mineralsFromOre(_ locationID: Int, _ settings: Settings, _ levels: [Int: Int]) async throws -> [Int: Int] {
        let (oreFactor, iceFactor) = try settings.factors(levels)
        let ores = try await oresAt(locationID)
        let info = try SDE.typesInfo(ores.keys)
        let dogma = SDE.reprocessSkills(ores.keys)
        var totals: [Int: Int] = [:]
        for (typeID, quantity) in ores {
            guard let t = info[typeID] else { continue }
            let group = t.string("group_name")
            let (rate, _) = try yieldFor(group, levels, oreFactor, iceFactor, skill: skillFor(typeID, group, dogma))
            for (material, amount) in reprocess(t, quantity, rate) {
                totals[material, default: 0] += amount
            }
        }
        return totals
    }

    static let oreLocationsFile = EngineSettings.appFolder.appending(path: "Config/ore_locations.json")

    /// Hand-maintained {family: {security, space, note}} – edit Config/ore_locations.json.
    static func oreLocations() -> [String: JSONDict] {
        // Your own edited copy first, else the one that ships inside the app.
        let shipped = Bundle.main.url(forResource: "ore_locations", withExtension: "json")
        guard let data = (try? Data(contentsOf: oreLocationsFile)) ?? shipped.flatMap({ try? Data(contentsOf: $0) }),
              let root = try? JSON.parse(data) as? JSONDict,
              let families = root["families"] as? [String: Any] else { return [:] }
        return families.compactMapValues { $0 as? JSONDict }
    }

    /// Every published ore / ice type and the materials it reprocesses into (most first).
    /// With refinery settings, also your yield and what one portion gives you after reprocessing.
    static func oreCatalog(_ settings: Settings?) async throws -> [JSONDict] {
        let rows = try SDE.connect().query("""
            SELECT t.type_id, t.name, g.name AS group_name
            FROM types t LEFT JOIN groups g ON g.group_id = t.group_id
            WHERE t.category_id = ? AND t.published = 1
            """, [asteroidCategory])
        let typeIDs = rows.compactMap { $0.int("type_id") }
        let info = try SDE.typesInfo(typeIDs)
        let dogma = SDE.reprocessSkills(typeIDs)
        let outputIDs = Set(info.values.flatMap { $0.dicts("materials").compactMap { $0.int("material_type_id") } })
        let names = try SDE.typeNames(outputIDs)
        let locations = oreLocations()

        var levels: [Int: Int]?
        var oreF = 0.0, iceF = 0.0
        if let settings {
            levels = (try? await Market.skillLevels()) ?? [:]
            (oreF, iceF) = try settings.factors(levels!)
        }

        var result: [JSONDict] = []
        for r in rows {
            guard let typeID = r.int("type_id") else { continue }
            let groupName = r.string("group_name")
            let name = r.string("name") ?? ""
            let whereFound = locations[groupName ?? ""] ?? [:]
            let materials = (info[typeID]?.dicts("materials") ?? [])
                .sorted { ($0.int("quantity") ?? 0) > ($1.int("quantity") ?? 0) }
            if materials.isEmpty { continue }
            let skill = skillFor(typeID, groupName, dogma)

            var yourYield: Double?
            var yourQuantities: [Int]?
            if let levels {
                yourYield = try yieldFor(groupName, levels, oreF, iceF, skill: skill).rate
                yourQuantities = materials.map { Int((Double($0.int("quantity") ?? 0) * yourYield!).rounded(.down)) }
            }
            result.append([
                "type_id": typeID,
                "name": name,
                "group_name": groupName as Any,
                "compressed": name.contains("Compressed "),
                "skill": skill as Any,
                "yield": yourYield as Any,
                "your_quantities": yourQuantities as Any,
                "outputs": materials.map { m -> String in
                    let id = m.int("material_type_id") ?? 0
                    return names[id] ?? String(id)
                },
                // Base amounts per portion, as shown on the item's Industry tab in game.
                "output_quantities": materials.map { $0.int("quantity") ?? 0 },
                "portion_size": info[typeID]?.int("portion_size").flatMap { $0 == 0 ? nil : $0 } ?? 1,
                "security": whereFound.value("security") as Any,
                "space": whereFound.value("space") as Any,
                "location_note": whereFound.value("note") as Any,
            ])
        }
        result.sort {
            let a = ($0.string("group_name") ?? "", $0.string("name") ?? "")
            let b = ($1.string("group_name") ?? "", $1.string("name") ?? "")
            return a < b
        }
        return result
    }

    /// Share of a sale lost to fees: sales tax, plus broker fee when listing a sell order.
    static func sellFeeRate(_ levels: [Int: Int], _ hubName: String, _ price: String) async throws -> Double {
        let accounting = Double(try level(levels, "Accounting"))
        var rate = 0.075 * (1 - 0.11 * accounting)
        if price == "sell" {
            var faction = 0.0, corp = 0.0
            if let hubInfo = try? await Market.hub(hubName), let standings = try? await Market.standings() {
                faction = standings[Market.standingKey("faction", hubInfo.int("owner_faction_id"))] ?? 0.0
                corp = standings[Market.standingKey("npc_corp", hubInfo.int("owner_corporation_id"))] ?? 0.0
            }
            let brokerRelations = Double(try level(levels, "Broker Relations"))
            let broker = 0.03 - 0.003 * brokerRelations - 0.0003 * faction - 0.0002 * corp
            rate += max(broker, 0.01)
        }
        return rate
    }

    /// Every ore at the refinery: what it reprocesses into, and whether to reprocess or sell.
    static func summary(_ locationID: Int, _ settings: Settings, hub: String = "Jita", price: String = "buy") async throws -> JSONDict {
        let levels = try await Market.skillLevels()
        let (oreFactor, iceFactor) = try settings.factors(levels)
        let ores = try await oresAt(locationID)
        let info = try SDE.typesInfo(ores.keys)
        let dogma = SDE.reprocessSkills(ores.keys)

        var outputIDs = Set<Int>()
        for t in ores.keys {
            for m in info[t]?.dicts("materials") ?? [] { if let id = m.int("material_type_id") { outputIDs.insert(id) } }
        }
        let books = try await Market.hubBooks(hub, Set(ores.keys).union(outputIDs))
        let adjusted = try await Market.adjustedPrices()
        let names = try SDE.typeNames(outputIDs)

        // Pre-pass: how much of each ore and mineral would be sold, so prices can be
        // depth-priced for that amount and checked against history (FairPrice).
        let sortedOres = ores.sorted { (info[$0.key]?.string("name") ?? "") < (info[$1.key]?.string("name") ?? "") }
        var amounts: [Int: Int] = [:]
        for (typeID, quantity) in sortedOres {
            guard let t = info[typeID] else { continue }
            let group = t.string("group_name")
            let (rate, _) = try yieldFor(group, levels, oreFactor, iceFactor, skill: skillFor(typeID, group, dogma))
            amounts[typeID, default: 0] += quantity
            for (material, amount) in reprocess(t, quantity, rate) { amounts[material, default: 0] += amount }
        }
        let fairSettings = FairPrice.Settings.current
        let pricedIDs = Array(amounts.keys)
        let historyList = try await concurrentMap(pricedIDs, limit: 16) { id -> JSONDict? in
            try? await Market.hubHistory(hub, id, days: fairSettings.lookbackDays)
        }
        var checks: [Int: JSONDict] = [:]
        for (id, history) in zip(pricedIDs, historyList) {
            let amount = amounts[id] ?? 1
            var live: Double?
            if let book = books[id] {
                let depth: Double? = price == "sell" ? FairPrice.sellDepthPrice(book, quantity: amount)
                                                     : FairPrice.buyDepthPrice(book, quantity: amount)
                live = depth ?? book.double(price)
            }
            checks[id] = FairPrice.check(live: live, history: history, quantity: amount, settings: fairSettings)
        }

        /// Checked market price for the amount you'd sell, else CCP's adjusted price.
        func unitPrice(_ typeID: Int) -> Double {
            checks[typeID]?.double("used") ?? adjusted[typeID] ?? 0.0
        }

        // Values below are what reaches your wallet: after selling fees (and refinery tax for minerals).
        let feeRate = try await sellFeeRate(levels, hub, price)

        var rows: [JSONDict] = []
        var mineralTotals: [Int: Int] = [:]
        var mineralOrder: [Int] = []
        for (typeID, quantity) in sortedOres {
            guard let t = info[typeID] else { continue }
            let group = t.string("group_name")
            let (rate, skill) = try yieldFor(group, levels, oreFactor, iceFactor, skill: skillFor(typeID, group, dogma))
            let outputs = reprocess(t, quantity, rate)
            let leftover = quantity % portionSize(t)

            var outputRows: [JSONDict] = []
            var mineralsValue = 0.0
            for (material, amount) in outputs.sorted(by: { $0.1 > $1.1 }) {
                let price: Double = unitPrice(material)
                let value: Double = Double(amount) * price
                let mineralTax: Double = settings.tax / 100 * Double(amount) * (adjusted[material] ?? 0.0)
                let mineralName: String = names[material] ?? String(material)
                mineralsValue += value
                if mineralTotals[material] == nil { mineralOrder.append(material) }
                mineralTotals[material, default: 0] += amount
                outputRows.append([
                    "type_id": material, "name": mineralName,
                    "quantity": amount, "unit_price": price, "value": value,
                    // Refinery tax on this mineral (charged on CCP's adjusted price).
                    "tax": mineralTax,
                    "price_status": checks[material]?.string("status") as Any,
                ])
            }

            // The game charges reprocessing tax on CCP's adjusted price of the output, not market value.
            let tax = settings.tax / 100 * outputs.reduce(0.0) { $0 + Double($1.1) * (adjusted[$1.0] ?? 0.0) }
            let asMinerals = mineralsValue * (1 - feeRate) - tax
            let asOre = Double(quantity) * unitPrice(typeID) * (1 - feeRate)
            let skillLevel = try level(levels, skill)
            let oreUnitPrice: Double = unitPrice(typeID)
            let better: String = asMinerals >= asOre ? "reprocess" : "sell"
            rows.append([
                "type_id": typeID,
                "name": t.string("name") as Any,
                "group_name": group as Any,
                "quantity": quantity,
                "leftover": leftover,
                "portion_size": portionSize(t),
                "skill": skill as Any,
                "skill_level": skillLevel,
                "yield_rate": rate,
                "outputs": outputRows,
                "minerals_value": mineralsValue,
                "tax": tax,
                "value_as_minerals": asMinerals,
                "ore_unit_price": oreUnitPrice,
                "value_as_ore": asOre,
                "better": better,
                "ore_check": checks[typeID] as Any,
            ])
        }

        let minerals: [JSONDict] = mineralOrder
            .map { ($0, mineralTotals[$0] ?? 0) }
            .sorted { $0.1 > $1.1 }
            .map { m, q in
                let price: Double = unitPrice(m)
                let value: Double = Double(q) * price
                let name: String = names[m] ?? String(m)
                let check: JSONDict? = checks[m]
                return ["type_id": m, "name": name, "quantity": q, "unit_price": price, "value": value,
                        "check": check as Any] as JSONDict
            }

        let totalAsOre: Double = rows.reduce(0.0) { $0 + ($1.double("value_as_ore") ?? 0) }
        let totalAsMinerals: Double = rows.reduce(0.0) { $0 + ($1.double("value_as_minerals") ?? 0) }
        let totalTax: Double = rows.reduce(0.0) { $0 + ($1.double("tax") ?? 0) }
        let reprocessingLevel = try level(levels, "Reprocessing")
        let efficiencyLevel = try level(levels, "Reprocessing Efficiency")
        return [
            "location_id": locationID,
            "hub": hub,
            "price": price,
            "ore_factor": oreFactor,
            "ice_factor": iceFactor,
            "sell_fee_rate": feeRate,
            "reprocessing_level": reprocessingLevel,
            "efficiency_level": efficiencyLevel,
            "ores": rows,
            "minerals": minerals,
            "total_value_as_ore": totalAsOre,
            "total_value_as_minerals": totalAsMinerals,
            "total_tax": totalTax,
            "lookback_days": fairSettings.lookbackDays,
        ]
    }
}
