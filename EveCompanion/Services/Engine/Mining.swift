import Foundation

/// Mining section: the ledger (what you mined, from the local history) and the Build Planner
/// (the mix of ore with the fewest m³ that covers the minerals for what you want to build).
enum Mining {

    // MARK: - Ledger

    static func ledger(hub: String) async throws -> JSONDict {
        await HistoryStore.shared.sync()
        let cid = try await EveAuth.shared.characterID()
        let days = HistoryRange.days
        let now = Date()
        let sinceDay = HistoryRange.since(days, now: now).map(ISODate.day)
        let rows = try await HistoryStore.shared.query(
            "SELECT date, type_id, solar_system_id, quantity FROM mining WHERE character_id = ? AND (? IS NULL OR date >= ?) ORDER BY date",
            [cid, sinceDay, sinceDay])
        let firstDay = try await HistoryStore.shared.query("SELECT MIN(date) AS first FROM mining WHERE character_id = ?", [cid])
            .first?.string("first")

        let typeIDs = Array(Set(rows.compactMap { $0.int("type_id") }))
        let names = try SDE.typeNames(typeIDs)
        var volumes: [Int: Double] = [:]
        if !typeIDs.isEmpty {
            for r in try SDE.connect().query("SELECT type_id, volume FROM types WHERE type_id IN (\(placeholders(typeIDs.count)))", typeIDs) {
                if let id = r.int("type_id") { volumes[id] = r.double("volume") ?? 0 }
            }
        }
        var books: [Int: JSONDict] = [:]
        if !typeIDs.isEmpty { books = try await Market.hubBooks(hub, typeIDs) }
        let average = try await Market.averagePrices()
        func price(_ typeID: Int) -> Double {
            books[typeID]?.double("buy").flatMap { $0 != 0 ? $0 : nil } ?? average[typeID] ?? 0
        }

        var dayUnits: [String: Int] = [:], dayM3: [String: Double] = [:], dayValue: [String: Double] = [:]
        var oreUnits: [Int: Int] = [:]
        var systemUnits: [Int: Int] = [:], systemValue: [Int: Double] = [:]
        var entries: [JSONDict] = []
        for r in rows {
            guard let typeID = r.int("type_id"), let date = r.string("date") else { continue }
            let qty = r.int("quantity") ?? 0
            let m3: Double = Double(qty) * (volumes[typeID] ?? 0)
            let value: Double = Double(qty) * price(typeID)
            dayUnits[date, default: 0] += qty
            dayM3[date, default: 0] += m3
            dayValue[date, default: 0] += value
            oreUnits[typeID, default: 0] += qty
            let system = r.int("solar_system_id") ?? 0
            systemUnits[system, default: 0] += qty
            systemValue[system, default: 0] += value
            entries.append(["date": date, "type_id": typeID, "name": names[typeID] ?? String(typeID),
                            "system_id": system, "units": qty, "m3": m3, "value": value])
        }

        var systemInfo: [Int: JSONDict] = [:]
        for id in systemUnits.keys { systemInfo[id] = (try? SDE.system(id)) ?? nil }
        for i in entries.indices {
            let id = entries[i].int("system_id") ?? 0
            entries[i]["system"] = systemInfo[id]?.string("name") ?? String(id)
        }

        // Every day of the range (or since the first entry for All), zero where nothing was mined.
        var daily: [JSONDict] = []
        let start = sinceDay ?? firstDay ?? ISODate.day(now)
        var cursor = ISODate.parse(start) ?? now
        while cursor <= now {
            let key = ISODate.day(cursor)
            let units: Int = dayUnits[key] ?? 0
            let m3: Double = dayM3[key] ?? 0
            let value: Double = dayValue[key] ?? 0
            daily.append(["date": key, "units": units, "m3": m3, "value": value])
            cursor = cursor.addingTimeInterval(86400)
        }

        let totalUnits = oreUnits.values.reduce(0, +)
        let totalValue = dayValue.values.reduce(0, +)
        let totalM3 = dayM3.values.reduce(0, +)
        let byOre: [JSONDict] = oreUnits.map { entry -> JSONDict in
            let (typeID, units) = entry
            let m3: Double = Double(units) * (volumes[typeID] ?? 0)
            let value: Double = Double(units) * price(typeID)
            let share: Double = totalValue > 0 ? value / totalValue : 0
            return ["type_id": typeID, "name": names[typeID] ?? String(typeID), "units": units, "m3": m3,
                    "value": value, "unit_price": price(typeID), "share": share]
        }.sorted { ($0.double("value") ?? 0) > ($1.double("value") ?? 0) }
        let bySystem: [JSONDict] = systemUnits.map { entry -> JSONDict in
            let (id, units) = entry
            let value: Double = systemValue[id] ?? 0
            return ["system_id": id, "name": systemInfo[id]?.string("name") ?? String(id),
                    "security": systemInfo[id]?.double("security") as Any, "units": units, "value": value]
        }.sorted { ($0.double("value") ?? 0) > ($1.double("value") ?? 0) }

        return [
            "range_label": HistoryRange.label(days),
            "history_since": firstDay as Any,
            "hub": hub,
            "total_units": totalUnits,
            "total_m3": totalM3,
            "total_value": totalValue,
            "days_mined": dayUnits.count,
            "daily": daily,
            "by_ore": byOre,
            "by_system": bySystem,
            "entries": Array(entries.reversed()),
        ]
    }

    // MARK: - Build Planner (was Ore Planner)

    struct PlanItem {
        let blueprintTypeID: Int
        let runs: Int
    }

    /// "123:10,456:2" → items
    static func parseItems(_ text: String) -> [PlanItem] {
        text.split(separator: ",").compactMap { part in
            let bits = part.split(separator: ":")
            guard let bp = bits.first.flatMap({ Int($0) }) else { return nil }
            let runs = bits.count > 1 ? (Int(bits[1]) ?? 1) : 1
            return PlanItem(blueprintTypeID: bp, runs: max(1, runs))
        }
    }

    struct Candidate {
        let typeID: Int
        let name: String
        let family: String
        let portion: Int
        let batchM3: Double
        let yieldRate: Double
        let materials: [(Int, Int)]       // (mineral, base quantity per batch)
        let space: String?
        let security: Double?
    }

    /// Security bands you mine in: "High" (0.5–1.0), "Low" (0.1–0.4), "Null" (0.0 and below), "Pochven".
    /// `beltSecurity` (ore_locations.json) is the safest security where the family appears in ordinary
    /// asteroid belts – nil for anomaly / special-site ore. Belt ore is found from there downwards,
    /// so it's available in a band if it reaches that band's top.
    static func oreAvailable(space: String?, beltSecurity: Double?, bands: Set<String>) -> Bool {
        guard let beltSecurity else { return false } // anomaly / site only, moon ore, ice
        if space == "Pochven" { return bands.contains("Pochven") }
        if bands.contains("High") && beltSecurity >= 0.45 { return true }
        if bands.contains("Low") && beltSecurity >= 0.05 { return true }
        if bands.contains("Null") { return true }
        return false
    }

    /// Grades found in ordinary belts: the plain ore, II-Grade and III-Grade
    /// (not IV-Grade, 0-Grade or special variants like Banidine / Augumene).
    static func isBeltGrade(_ name: String, family: String) -> Bool {
        name == family || name == "\(family) II-Grade" || name == "\(family) III-Grade"
    }

    /// "0.9 · High" style label for where belt ore starts.
    static func beltSpace(_ space: String?, _ beltSecurity: Double) -> String {
        if space == "Pochven" { return "Pochven" }
        if beltSecurity >= 0.45 { return "High" }
        if beltSecurity >= 0.05 { return "Low" }
        return "Null"
    }

    static func buildPlan(items: [PlanItem], structure: String, rigME: Double, subtractStock: Bool,
                     stockLocation: Int?, refineryLocation: Int?, settings: Reprocessing.Settings,
                     bands: Set<String>, hub: String, breakDown: Bool = true) async throws -> JSONDict {
        let levels = try await Market.skillLevels()
        let bonuses = IndustryCalc.structures[structure] ?? IndustryCalc.structures["npc"]!

        // ---- What the builds need ----
        var bestME: [Int: Int] = [:]
        for bp in (try? await ESI.characterBlueprints()) ?? [] {
            guard let type = bp.int("type_id") else { continue }
            bestME[type] = max(bestME[type] ?? 0, bp.int("material_efficiency") ?? 0)
        }
        var needed: [Int: Int] = [:]
        var neededOrder: [Int] = []
        var itemRows: [JSONDict] = []
        var materialNames: [Int: String] = [:]
        for item in items {
            guard let data = try SDE.manufacturing(item.blueprintTypeID) else { continue }
            let me = bestME[item.blueprintTypeID] ?? 0
            let mod = (1 - Double(me) / 100) * (1 - bonuses.me) * (1 - rigME / 100)
            let bp = data.dict("blueprint") ?? [:]
            itemRows.append([
                "blueprint_type_id": item.blueprintTypeID,
                "product_type_id": bp.int("product_type_id") ?? 0,
                "product_name": bp.string("product_name") ?? "",
                "runs": item.runs,
                "units": item.runs * (bp.int("product_quantity") ?? 1),
                "me": me,
            ])
            for m in data.dicts("materials") {
                let type = m.int("material_type_id") ?? 0
                let required = max(item.runs, IndustryCalc.ceilRounded(Double(item.runs * (m.int("quantity") ?? 0)) * mod))
                if needed[type] == nil { neededOrder.append(type) }
                needed[type, default: 0] += required
                materialNames[type] = m.string("name") ?? materialNames[type]
            }
        }

        // ---- What you already have ----
        var have: [Int: Int] = [:]
        var warnings: [String] = []
        if subtractStock {
            do { have = try await Market.ownedQuantities(stockLocation) }
            catch { warnings.append("Couldn't read your assets: \(error.localizedDescription)") }
            if let refineryLocation, refineryLocation != 0 {
                do {
                    for (type, qty) in try await Reprocessing.mineralsFromOre(refineryLocation, settings, levels) {
                        have[type, default: 0] += qty
                    }
                } catch { warnings.append("Couldn't work out minerals from your ore: \(error.localizedDescription)") }
            }
        }

        // ---- Components: build them yourself (break down into their own materials) ----
        // Anything in the list that has a manufacturing blueprint is built from its materials,
        // using what you already have of it first. Repeats down the chain (components of
        // components) until only minerals and things you'd buy are left.
        var buildFirst: [JSONDict] = []
        if breakDown {
            let db = try SDE.connect()
            let byProduct = try db.prepare("""
                SELECT m.blueprint_type_id, m.product_quantity FROM bp_manufacturing m
                JOIN types b ON b.type_id = m.blueprint_type_id
                WHERE m.product_type_id = ? AND b.published = 1 LIMIT 1
                """)
            var queue = neededOrder
            var expanded = Set<Int>()
            var guardCount = 0
            while !queue.isEmpty, guardCount < 500 {
                guardCount += 1
                let type = queue.removeFirst()
                guard !expanded.contains(type), let blueprint = try byProduct.rows([type]).first,
                      let bpID = blueprint.int("blueprint_type_id"),
                      let data = try SDE.manufacturing(bpID) else { continue }
                expanded.insert(type)
                let perRun = max(1, blueprint.int("product_quantity") ?? 1)
                let wanted = needed[type] ?? 0
                let fromStock = min(have[type] ?? 0, wanted)
                let toBuild = wanted - fromStock
                let runs = toBuild > 0 ? (toBuild + perRun - 1) / perRun : 0
                let me = bestME[bpID] ?? 0
                buildFirst.append([
                    "type_id": type, "blueprint_type_id": bpID,
                    "name": (data.dict("blueprint")?.string("product_name")) ?? materialNames[type] ?? String(type),
                    "needed": wanted, "have": fromStock, "to_build": toBuild, "runs": runs,
                    "me": me, "owned": bestME[bpID] != nil,
                ])
                guard runs > 0 else { continue }
                let mod = (1 - Double(me) / 100) * (1 - bonuses.me) * (1 - rigME / 100)
                for m in data.dicts("materials") {
                    let sub = m.int("material_type_id") ?? 0
                    let required = max(runs, IndustryCalc.ceilRounded(Double(runs * (m.int("quantity") ?? 0)) * mod))
                    if needed[sub] == nil { neededOrder.append(sub) }
                    needed[sub, default: 0] += required
                    materialNames[sub] = m.string("name") ?? materialNames[sub]
                    if !expanded.contains(sub) { queue.append(sub) }
                }
            }
        }
        let builtTypes = Set(buildFirst.compactMap { $0.int("type_id") })

        // ---- Ores you could mine ----
        let (oreFactor, iceFactor) = try settings.factors(levels)
        let locations = Reprocessing.oreLocations()
        let oreRows = try SDE.connect().query("""
            SELECT t.type_id, t.name, t.volume, t.portion_size, g.name AS group_name
            FROM types t LEFT JOIN groups g ON g.group_id = t.group_id
            WHERE t.category_id = ? AND t.published = 1
            """, [Reprocessing.asteroidCategory])
        let oreIDs = oreRows.compactMap { $0.int("type_id") }
        let info = try SDE.typesInfo(oreIDs)
        let dogma = SDE.reprocessSkills(oreIDs)
        var candidates: [Candidate] = []          // the standard ore of each family – what the plan is built on
        var graded: [String: [Candidate]] = [:]   // family → II-Grade / III-Grade, shown as alternatives
        for r in oreRows {
            guard let typeID = r.int("type_id"), let name = r.string("name"),
                  !name.contains("Compressed"), let t = info[typeID] else { continue }
            let materials = t.dicts("materials").map { ($0.int("material_type_id") ?? 0, $0.int("quantity") ?? 0) }
            guard !materials.isEmpty else { continue }
            let family = r.string("group_name") ?? ""
            guard isBeltGrade(name, family: family) else { continue }
            let place = locations[family]
            let beltSecurity = place?.double("belt_security")
            if !oreAvailable(space: place?.string("space"), beltSecurity: beltSecurity, bands: bands) { continue }
            let space = beltSecurity.map { beltSpace(place?.string("space"), $0) }
            let portion = max(1, r.int("portion_size") ?? 1)
            let volume = r.double("volume") ?? 0
            guard volume > 0 else { continue }
            let skill = Reprocessing.skillFor(typeID, family, dogma)
            let rate = try Reprocessing.yieldFor(family, levels, oreFactor, iceFactor, skill: skill).rate
            let candidate = Candidate(typeID: typeID, name: name, family: family, portion: portion,
                                      batchM3: Double(portion) * volume, yieldRate: rate, materials: materials,
                                      space: space, security: beltSecurity)
            if name == family {
                candidates.append(candidate)
            } else {
                graded[family, default: []].append(candidate)
            }
        }

        // Minerals the ores can give vs everything else (components, PI, etc. – buy those).
        let mineable = Set(candidates.flatMap { $0.materials.map { $0.0 } })
        var toMine: [Int: Int] = [:]
        var otherNeeds: [JSONDict] = []
        let allNames = try SDE.typeNames(neededOrder)
        for type in neededOrder where !builtTypes.contains(type) {
            let shortfall = max(0, (needed[type] ?? 0) - (have[type] ?? 0))
            if mineable.contains(type) {
                if shortfall > 0 { toMine[type] = shortfall }
            } else {
                otherNeeds.append(["type_id": type, "name": allNames[type] ?? materialNames[type] ?? String(type),
                                   "needed": needed[type] ?? 0, "have": have[type] ?? 0, "to_get": shortfall])
            }
        }

        // ---- Fewest m³: linear programme, then whole batches ----
        // Only minerals some candidate ore actually gives (the rest are reported as unreachable).
        let minerals = toMine.keys.sorted().filter { mineral in
            candidates.contains { c in c.materials.contains { $0.0 == mineral && $0.1 > 0 } }
        }
        var batches = [Int](repeating: 0, count: candidates.count)
        if !minerals.isEmpty && !candidates.isEmpty {
            // a[i][j] = mineral i per batch of ore j (before rounding down)
            let a: [[Double]] = minerals.map { mineral in
                candidates.map { c in
                    Double(c.materials.first { $0.0 == mineral }?.1 ?? 0) * c.yieldRate
                }
            }
            let b = minerals.map { Double(toMine[$0] ?? 0) }
            let cost = candidates.map(\.batchM3)
            let x = minimiseCost(a: a, b: b, cost: cost) ?? [Double](repeating: 0, count: candidates.count)
            batches = x.map { Int(($0 - 1e-7).rounded(.up)) }.map { max(0, $0) }

            func produced(_ batches: [Int]) -> [Int: Int] {
                var out: [Int: Int] = [:]
                for (j, c) in candidates.enumerated() where batches[j] > 0 {
                    for (mineral, base) in c.materials {
                        out[mineral, default: 0] += Int((Double(batches[j]) * Double(base) * c.yieldRate).rounded(.down))
                    }
                }
                return out
            }
            func short(_ batches: [Int]) -> Int? {
                let out = produced(batches)
                return minerals.first { (out[$0] ?? 0) < (toMine[$0] ?? 0) }
            }
            // Top up anything rounding left short with the most m³-efficient ore for it.
            var guardCount = 0
            while let mineral = short(batches), guardCount < 10_000 {
                guardCount += 1
                let best = candidates.indices
                    .filter { j in candidates[j].materials.contains { $0.0 == mineral && $0.1 > 0 } }
                    .max { j, k in
                        let yj = Double(candidates[j].materials.first { $0.0 == mineral }!.1) * candidates[j].yieldRate / candidates[j].batchM3
                        let yk = Double(candidates[k].materials.first { $0.0 == mineral }!.1) * candidates[k].yieldRate / candidates[k].batchM3
                        return yj < yk
                    }
                guard let best else { break }
                batches[best] += 1
            }
            // Trim batches that aren't needed after rounding (biggest m³ first).
            for j in candidates.indices.sorted(by: { candidates[$0].batchM3 > candidates[$1].batchM3 }) {
                while batches[j] > 0 {
                    batches[j] -= 1
                    if short(batches) != nil { batches[j] += 1; break }
                }
            }
        }

        // ---- Results ----
        var producedTotals: [Int: Int] = [:]
        var oreRowsOut: [JSONDict] = []
        let mineralNames = try SDE.typeNames(Set(candidates.flatMap { $0.materials.map { $0.0 } }))
        for (j, c) in candidates.enumerated() where batches[j] > 0 {
            var gives: [JSONDict] = []
            for (mineral, base) in c.materials {
                let qty = Int((Double(batches[j]) * Double(base) * c.yieldRate).rounded(.down))
                producedTotals[mineral, default: 0] += qty
                gives.append(["type_id": mineral, "name": mineralNames[mineral] ?? String(mineral), "quantity": qty])
            }
            let units: Int = batches[j] * c.portion
            let m3: Double = Double(batches[j]) * c.batchM3

            // The same minerals from each grade instead: graded ore gives more per unit, so fewer units.
            var target: [Int: Int] = [:]
            for (mineral, base) in c.materials {
                target[mineral] = Int((Double(batches[j]) * Double(base) * c.yieldRate).rounded(.down))
            }
            var variants: [JSONDict] = [variantRow(c, grade: "Standard", batches: batches[j], names: mineralNames)]
            let grades = (graded[c.family] ?? []).sorted { $0.name.count < $1.name.count } // II before III
            for g in grades {
                let b = batchesToMatch(g, target: target)
                variants.append(variantRow(g, grade: g.name.hasSuffix("III-Grade") ? "III-Grade" : "II-Grade",
                                           batches: b, names: mineralNames))
            }

            oreRowsOut.append([
                "type_id": c.typeID, "name": c.name, "family": c.family, "batches": batches[j], "units": units,
                "m3": m3, "yield": c.yieldRate, "space": c.space as Any, "security": c.security as Any,
                "gives": gives.sorted { ($0.int("quantity") ?? 0) > ($1.int("quantity") ?? 0) },
                "variants": variants,
            ])
        }
        oreRowsOut.sort { ($0.double("m3") ?? 0) > ($1.double("m3") ?? 0) }

        var unreachable: [String] = []
        var mineralRows: [JSONDict] = []
        for type in neededOrder where mineable.contains(type) {
            let need = needed[type] ?? 0
            let got = have[type] ?? 0
            let mine = toMine[type] ?? 0
            let plan = producedTotals[type] ?? 0
            if mine > 0 && plan < mine { unreachable.append(mineralNames[type] ?? String(type)) }
            mineralRows.append(["type_id": type, "name": mineralNames[type] ?? String(type), "needed": need,
                                "have": got, "to_mine": mine, "plan_gives": plan, "spare": max(0, plan - mine)])
        }
        if !unreachable.isEmpty {
            warnings.append("No ore in \(bandList(bands)) gives \(unreachable.joined(separator: ", ")) – tick more areas or buy it.")
        }

        // ---- Where the rest comes from, and what it all costs ----
        // Buy items are priced at the hub's cheapest sell order (what you'd pay), minerals at
        // the hub's best buy order (what they're worth to you); CCP's average price otherwise.
        let sourceDB = try SDE.connect()
        let otherIDs = otherNeeds.compactMap { $0.int("type_id") }
        var sources: [Int: String] = [:]
        if !otherIDs.isEmpty {
            let list = otherIDs.map(String.init).joined(separator: ",")
            // (try? – an older static-data file without this table just means no "reaction" labels yet)
            let reactionRows = (try? sourceDB.query(
                "SELECT product_type_id FROM reaction_products WHERE product_type_id IN (\(list))")) ?? []
            let reactionIDs = Set(reactionRows.compactMap { $0.int("product_type_id") })
            for r in try sourceDB.query("""
                SELECT t.type_id, g.name AS group_name, c.name AS category_name FROM types t
                LEFT JOIN groups g ON g.group_id = t.group_id
                LEFT JOIN categories c ON c.category_id = t.category_id
                WHERE t.type_id IN (\(list))
                """) {
                guard let id = r.int("type_id") else { continue }
                let group = r.string("group_name") ?? ""
                let category = r.string("category_name") ?? ""
                if reactionIDs.contains(id) { sources[id] = "reaction" }
                else if category.hasPrefix("Planetary") { sources[id] = "planetary" }
                else if group == "Moon Materials" { sources[id] = "moon" }
                else if group.contains("Salvage") { sources[id] = "salvage" }
                else { sources[id] = "buy" }
            }
        }
        let mineralIDs = mineralRows.compactMap { $0.int("type_id") }
        let priceFetch = try await Market.hubBooksAllowingGaps(hub, Set(otherIDs + mineralIDs))
        let averages = (try? await Market.averagePrices()) ?? [:]
        var buyTotal = 0.0
        for index in otherNeeds.indices {
            let id = otherNeeds[index].int("type_id") ?? 0
            let price: Double? = priceFetch.books[id]?.double("sell") ?? averages[id].flatMap { $0 > 0 ? $0 : nil }
            let toGet = Double(otherNeeds[index].int("to_get") ?? 0)
            let value: Double? = price.map { $0 * toGet }
            otherNeeds[index]["source"] = sources[id] ?? "buy"
            otherNeeds[index]["unit_price"] = price as Any
            otherNeeds[index]["value"] = value as Any
            buyTotal += value ?? 0
        }
        var mineralsTotal = 0.0
        for index in mineralRows.indices {
            let id = mineralRows[index].int("type_id") ?? 0
            let price: Double? = priceFetch.books[id]?.double("buy") ?? averages[id].flatMap { $0 > 0 ? $0 : nil }
            let toMine = Double(mineralRows[index].int("to_mine") ?? 0)
            let value: Double? = price.map { $0 * toMine }
            mineralRows[index]["unit_price"] = price as Any
            mineralRows[index]["value"] = value as Any
            mineralsTotal += value ?? 0
        }
        let ownedComponentBlueprints: Int = buildFirst.filter { $0.bool("owned") }.count

        let totalM3: Double = oreRowsOut.reduce(0.0) { $0 + ($1.double("m3") ?? 0) }
        let totalUnits: Int = oreRowsOut.reduce(0) { $0 + ($1.int("units") ?? 0) }
        return [
            "buy_total": buyTotal,
            "minerals_total": mineralsTotal,
            "owned_component_blueprints": ownedComponentBlueprints,
            "price_hub": hub,
            "items": itemRows,
            "ores": oreRowsOut,
            "minerals": mineralRows,
            "other_materials": otherNeeds,
            "build_first": buildFirst,
            "break_down": breakDown,
            "total_m3": totalM3,
            "total_units": totalUnits,
            "candidates": candidates.count,
            "highsec_only": bands == ["High"],
            "bands": bandList(bands),
            "warnings": warnings,
        ]
    }

    /// Fewest whole batches of `ore` that give at least `target` of every mineral.
    static func batchesToMatch(_ ore: Candidate, target: [Int: Int]) -> Int {
        var batches = 0
        for (mineral, base) in ore.materials {
            let need = Double(target[mineral] ?? 0)
            let perBatch = Double(base) * ore.yieldRate
            if need > 0, perBatch > 0 { batches = max(batches, Int((need / perBatch).rounded(.up))) }
        }
        func enough(_ b: Int) -> Bool {
            ore.materials.allSatisfy { mineral, base in
                Int((Double(b) * Double(base) * ore.yieldRate).rounded(.down)) >= (target[mineral] ?? 0)
            }
        }
        while !enough(batches) { batches += 1 }
        while batches > 0 && enough(batches - 1) { batches -= 1 }
        return batches
    }

    static func variantRow(_ ore: Candidate, grade: String, batches: Int, names: [Int: String]) -> JSONDict {
        let gives: [JSONDict] = ore.materials.map { mineral, base in
            let qty = Int((Double(batches) * Double(base) * ore.yieldRate).rounded(.down))
            return ["type_id": mineral, "name": names[mineral] ?? String(mineral), "quantity": qty]
        }
        let units: Int = batches * ore.portion
        let m3: Double = Double(batches) * ore.batchM3
        return ["type_id": ore.typeID, "name": ore.name, "grade": grade, "batches": batches,
                "units": units, "m3": m3, "gives": gives]
    }

    static func bandList(_ bands: Set<String>) -> String {
        ["High", "Low", "Null", "Pochven"].filter { bands.contains($0) }
            .map { $0 == "Pochven" ? "Pochven" : "\($0)-sec" }.joined(separator: " / ")
    }

    /// Minimise cost·x subject to a·x ≥ b, x ≥ 0 (a: minerals × ores).
    /// Solved through its dual (maximise b·y, aᵀy ≤ cost, y ≥ 0), which starts feasible at y = 0,
    /// with Bland's rule against cycling. x is read from the slack columns of the final tableau.
    /// Returns nil when some requirement can't be met.
    static func minimiseCost(a: [[Double]], b: [Double], cost: [Double]) -> [Double]? {
        let m = b.count, n = cost.count
        guard m > 0, n > 0 else { return [Double](repeating: 0, count: n) }
        let eps = 1e-9
        let width = m + n + 1
        // Rows 0..<n: one per ore (dual constraint); last row: objective.
        var t = [[Double]](repeating: [Double](repeating: 0, count: width), count: n + 1)
        for j in 0..<n {
            for i in 0..<m { t[j][i] = a[i][j] }
            t[j][m + j] = 1
            t[j][width - 1] = cost[j]
        }
        for i in 0..<m { t[n][i] = -b[i] }
        var basis = (0..<n).map { m + $0 }

        for _ in 0..<50_000 {
            guard let entering = (0..<(m + n)).first(where: { t[n][$0] < -eps }) else { break }
            var leaving: Int?
            var bestRatio = Double.infinity
            for row in 0..<n where t[row][entering] > eps {
                let ratio = t[row][width - 1] / t[row][entering]
                if ratio < bestRatio - eps || (abs(ratio - bestRatio) <= eps && leaving.map { basis[row] < basis[$0] } ?? true) {
                    bestRatio = ratio
                    leaving = row
                }
            }
            guard let pivotRow = leaving else { return nil } // dual unbounded → requirements can't be met
            let pivot = t[pivotRow][entering]
            for col in 0..<width { t[pivotRow][col] /= pivot }
            for row in 0...n where row != pivotRow {
                let factor = t[row][entering]
                if abs(factor) > eps {
                    for col in 0..<width { t[row][col] -= factor * t[pivotRow][col] }
                }
            }
            basis[pivotRow] = entering
        }
        return (0..<n).map { max(0, t[n][m + $0]) }
    }
}
