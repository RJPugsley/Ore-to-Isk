import Foundation

/// Mine / Sell › Reprocess or Sell: for loot, salvage, old modules (and ore), is a stack worth more
/// sold as it is, or reprocessed – and, where what comes out reprocesses again, broken down further?
///
///   value(item, qty) = max(sell as is, Σ value(each output) − reprocessing tax)   – the same question
///                      asked again for every output, down to things that don't reprocess any more.
///   ore / ice yield  = place factor × (1 + 3% Reprocessing) × (1 + 2% Efficiency) × (1 + 2% ore skill)
///   anything else    = place's equipment (50% almost everywhere) × (1 + 2% Scrapmetal Processing);
///                      refinery rigs, implants and the ore skills don't help scrap.
///   output           = floor(floor(qty ÷ portion) × base × yield)
///   tax              = place's tax rate × CCP adjusted value of the output
///                      NPC station: station's take × (1 − owner-corp standing ÷ 6.67), 0 at 6.67+
///   selling          = depth price for the amount at the hub, checked against the fair price,
///                      after sales tax (+ broker fee when listing)
/// One hub per item: with "best", each item is priced at whichever single hub gives the best total.
enum ReprocessOrSell {
    static let maxDepth = 6
    static let eitherBand = 0.05
    static let blueprintCategory = 9
    static let skillCategory = 16
    private static let fittedPrefixes = ["HiSlot", "MedSlot", "LoSlot", "RigSlot", "SubSystemSlot", "ServiceSlot"]
    private static let notCargo: Set<String> = ["Implant", "Skill", "SkillInTraining", "AutoFit"]

    // MARK: - Places

    /// Where a stack gets reprocessed and what that place gives / takes.
    struct Place {
        var id: Int
        var name: String
        var oreFactor: Double
        var iceFactor: Double
        var scrapBase: Double
        /// Share of the output's CCP adjusted value taken as tax.
        var taxRate: Double
        var canReprocess: Bool
        /// Player structure (not your refinery): the owner's settings aren't readable – estimated.
        var estimated: Bool
        var isRefinery: Bool

        var json: JSONDict {
            ["location_id": id, "name": name, "ore_factor": oreFactor, "scrap_base": scrapBase, "tax_rate": taxRate,
             "can_reprocess": canReprocess, "estimated": estimated, "is_refinery": isRefinery]
        }
    }

    private static func stationInfo(_ id: Int) async -> JSONDict? {
        // Same cache as Hauling.systemOf.
        let station: Any? = try? await cached("station:\(id)", ttl: 7 * 24 * 3600) { () async throws -> Any in
            try await ESI.get("universe/stations/\(id)/", auth: false)
        }
        return station as? JSONDict
    }

    /// A plain NPC station (50% equipment, 5% tax) – Look Up without a refinery set.
    static let plainStation = Place(id: 0, name: "a standard NPC station", oreFactor: 0.5, iceFactor: 0.5,
                                    scrapBase: 0.5, taxRate: 0.05, canReprocess: true, estimated: true,
                                    isRefinery: false)

    static func place(_ id: Int, name: String, refineryID: Int, settings: Reprocessing.Settings,
                      levels: [Int: Int], standings: [String: Double]) async throws -> Place {
        if id == 0 { return plainStation }
        if id == refineryID {
            let factors = try settings.factors(levels)
            return Place(id: id, name: name, oreFactor: factors.ore, iceFactor: factors.ice, scrapBase: 0.5,
                         taxRate: max(settings.tax, 0) / 100, canReprocess: true, estimated: false, isRefinery: true)
        }
        if ESI.isStation(id) {
            let info = await stationInfo(id)
            let services = (info?["services"] as? [String]) ?? []
            let canReprocess = info == nil || services.contains("reprocessing-plant")
            let equipment = info?.double("reprocessing_efficiency") ?? 0.5
            let take = info?.double("reprocessing_stations_take") ?? 0.05
            let standing = max(standings[Market.standingKey("npc_corp", info?.int("owner"))] ?? 0, 0)
            let tax = max(0, take * (1 - standing / 6.67))
            return Place(id: id, name: name, oreFactor: equipment, iceFactor: equipment, scrapBase: equipment,
                         taxRate: tax, canReprocess: canReprocess, estimated: info == nil, isRefinery: false)
        }
        // Someone's structure: rigs and tax unknown – 50% and your refinery's tax as a guess.
        return Place(id: id, name: name, oreFactor: 0.5, iceFactor: 0.5, scrapBase: 0.5,
                     taxRate: max(settings.tax, 0) / 100, canReprocess: true, estimated: true, isRefinery: false)
    }

    // MARK: - Context (static data + prices)

    struct Context {
        var info: [Int: JSONDict]
        var dogma: [Int: String]
        var levels: [Int: Int]
        var books: [String: [Int: JSONDict]]
        var histories: [String: [Int: JSONDict]]
        var adjusted: [Int: Double]
        var feeRates: [String: Double]
        var price: String
        var fair: FairPrice.Settings
        var priceGaps: Int

        /// Checked price per unit for `quantity` at the hub (nil = nobody to sell to there).
        func unit(_ hub: String, _ typeID: Int, _ quantity: Int) -> (price: Double?, check: JSONDict?) {
            guard let book = books[hub]?[typeID] else { return (nil, nil) }
            let depth: Double? = price == "sell" ? FairPrice.sellDepthPrice(book, quantity: quantity)
                                                 : FairPrice.buyDepthPrice(book, quantity: quantity)
            let live: Double? = depth ?? book.double(price)
            let check = FairPrice.check(live: live, history: histories[hub]?[typeID], quantity: quantity, settings: fair)
            return (check.double("used"), check)
        }

        func yieldRate(_ typeID: Int, at place: Place) throws -> Double {
            let t = info[typeID] ?? [:]
            if t.int("category_id") == Reprocessing.asteroidCategory {
                let group = t.string("group_name")
                return try Reprocessing.yieldFor(group, levels, place.oreFactor, place.iceFactor,
                                                 skill: Reprocessing.skillFor(typeID, group, dogma)).rate
            }
            let scrap = Double(try Reprocessing.level(levels, "Scrapmetal Processing"))
            return min(1.0, place.scrapBase * (1 + 0.02 * scrap))
        }
    }

    /// Static data for the types and everything they break down into (down to `maxDepth`).
    private static func treeInfo(_ roots: Set<Int>) throws -> [Int: JSONDict] {
        var info: [Int: JSONDict] = [:]
        var frontier = roots
        var depth = 0
        while !frontier.isEmpty && depth <= maxDepth + 1 {
            let got = try SDE.typesInfo(frontier)
            var next = Set<Int>()
            for (id, t) in got {
                info[id] = t
                for m in t.dicts("materials") {
                    if let mid = m.int("material_type_id"), info[mid] == nil, got[mid] == nil { next.insert(mid) }
                }
            }
            frontier = next.subtracting(info.keys)
            depth += 1
        }
        return info
    }

    private static func marketable(_ ids: [Int]) throws -> [Int] {
        guard !ids.isEmpty else { return [] }
        return try SDE.connect().query(
            "SELECT type_id FROM types WHERE market_group_id IS NOT NULL AND type_id IN (\(placeholders(ids.count)))", ids
        ).compactMap { $0.int("type_id") }
    }

    static func context(roots: Set<Int>, hubs: [String], price: String) async throws -> Context {
        let info = try treeInfo(roots)
        let ids = Array(info.keys)
        let levels = try await Market.skillLevels()
        let fair = FairPrice.Settings.current
        let market = try marketable(ids)

        var books: [String: [Int: JSONDict]] = [:]
        var gaps = 0
        for hub in hubs {
            let (got, failed) = try await Market.hubBooksAllowingGaps(hub, market)
            books[hub] = got
            gaps += failed.count
        }
        struct Pair { let hub: String; let type: Int }
        let pairs: [Pair] = hubs.flatMap { hub in market.map { Pair(hub: hub, type: $0) } }
        let historyList = try await concurrentMap(pairs, limit: 16) { pair -> JSONDict? in
            try? await Market.hubHistory(pair.hub, pair.type, days: fair.lookbackDays)
        }
        var histories: [String: [Int: JSONDict]] = [:]
        for (pair, history) in zip(pairs, historyList) {
            if let history { histories[pair.hub, default: [:]][pair.type] = history }
        }
        var feeRates: [String: Double] = [:]
        for hub in hubs { feeRates[hub] = try await Reprocessing.sellFeeRate(levels, hub, price) }

        let adjusted = try await Market.adjustedPrices()
        let dogma = SDE.reprocessSkills(ids)
        return Context(info: info, dogma: dogma, levels: levels, books: books,
                       histories: histories, adjusted: adjusted, feeRates: feeRates,
                       price: price, fair: fair, priceGaps: gaps)
    }

    // MARK: - The breakdown tree

    struct Node {
        var typeID: Int
        var name: String
        var quantity: Int
        var unitPrice: Double?
        var check: JSONDict?
        var asIs: Double?
        var reprocessed: Double?
        var tax = 0.0
        var yieldRate: Double?
        var portion = 1
        var leftover = 0
        /// Why it wasn't broken down (when it has materials): "too_small" · "no_reprocessing" · "depth".
        var stop: String?
        var outputs: [Node] = []
        /// "reprocess" · "sell" · "none" (no buyers and nothing to break down into)
        var choice = "none"
        var value = 0.0

        var json: JSONDict {
            [
                "type_id": typeID, "name": name, "quantity": quantity,
                "unit_price": unitPrice as Any, "check": check as Any,
                "as_is": asIs as Any, "reprocessed": reprocessed as Any, "tax": tax,
                "yield_rate": yieldRate as Any, "portion_size": portion, "leftover": leftover,
                "stop": stop as Any, "choice": choice, "value": value,
                "outputs": outputs.map { $0.json },
            ]
        }
    }

    static func evaluate(_ typeID: Int, _ quantity: Int, at place: Place, hub: String, _ ctx: Context,
                         depth: Int = 0, path: Set<Int> = []) throws -> Node {
        let t = ctx.info[typeID]
        var node = Node(typeID: typeID, name: t?.string("name") ?? String(typeID), quantity: quantity)
        let (unit, check) = ctx.unit(hub, typeID, quantity)
        node.unitPrice = unit
        node.check = check
        let fee = ctx.feeRates[hub] ?? 0
        if let unit { node.asIs = Double(quantity) * unit * (1 - fee) }

        let materials = t?.dicts("materials") ?? []
        if let t, !materials.isEmpty {
            node.portion = Reprocessing.portionSize(t)
            node.leftover = quantity % node.portion
            if !place.canReprocess {
                node.stop = "no_reprocessing"
            } else if depth >= maxDepth || path.contains(typeID) {
                node.stop = "depth"
            } else if quantity < node.portion {
                node.stop = "too_small"
            } else {
                let rate = try ctx.yieldRate(typeID, at: place)
                node.yieldRate = rate
                var sum = 0.0
                var tax = 0.0
                for (material, amount) in Reprocessing.reprocess(t, quantity, rate) where amount > 0 {
                    let child = try evaluate(material, amount, at: place, hub: hub, ctx,
                                             depth: depth + 1, path: path.union([typeID]))
                    sum += child.value
                    tax += place.taxRate * Double(amount) * (ctx.adjusted[material] ?? 0)
                    node.outputs.append(child)
                }
                node.outputs.sort { $0.value > $1.value }
                node.tax = tax
                node.reprocessed = sum - tax
            }
        }

        if let reprocessed = node.reprocessed, reprocessed > (node.asIs ?? 0) {
            node.choice = "reprocess"
            node.value = reprocessed
        } else if let asIs = node.asIs {
            node.choice = "sell"
            node.value = asIs
        }
        return node
    }

    /// "reprocess" · "sell" · "either" (within 5%) · "no_market" · "nothing"
    static func verdict(asIs: Double?, reprocessed: Double?) -> String {
        guard let reprocessed else { return asIs == nil ? "nothing" : "sell" }
        guard let asIs, asIs > 0 else { return reprocessed > 0 ? "reprocess" : "nothing" }
        let change = (reprocessed - asIs) / asIs
        if abs(change) <= eitherBand { return "either" }
        return change > 0 ? "reprocess" : "sell"
    }

    /// The best (hub, place) for one stack, plus each place's best reprocessed value.
    struct StackResult {
        var node: Node
        var hub: String
        var place: Place
        var byPlace: [Int: Double?] = [:]
    }

    static func best(_ typeID: Int, _ quantity: Int, places: [Place], hubs: [String], _ ctx: Context) throws -> StackResult {
        var result: StackResult?
        var byPlace: [Int: Double?] = [:]
        for place in places {
            var placeBest: Double?
            for hub in hubs {
                let node = try evaluate(typeID, quantity, at: place, hub: hub, ctx)
                if let r = node.reprocessed { placeBest = max(placeBest ?? r, r) }
                if result == nil || node.value > result!.node.value + 0.005 {
                    result = StackResult(node: node, hub: hub, place: place)
                }
            }
            byPlace[place.id] = placeBest
        }
        guard var result else { throw ValueError("Nothing to compare") }
        result.byPlace = byPlace
        return result
    }

    // MARK: - Assets

    struct Stack: Hashable { let typeID: Int; let location: Int }

    /// What you own that reprocesses into something, per station: no assembled ships, nothing fitted
    /// to or carried in one, no blueprints / skills, no assembled containers holding things.
    static func ownedStacks(locationID: Int) async throws -> (stacks: [Stack: Int], skippedShips: Int, skippedOre: Int, info: [Int: JSONDict]) {
        let byItem = try await ESI.getAssets().byItem
        let info = try SDE.typesInfo(Set(byItem.values.compactMap { $0.int("type_id") }))
        let parents = Set(byItem.values.compactMap { $0.int("location_id") })

        func isAssembledShip(_ a: JSONDict) -> Bool {
            a.bool("is_singleton") && info[a.int("type_id") ?? 0]?.int("category_id") == SDE.shipCategory
        }
        func insideShip(_ a: JSONDict) -> Bool {
            var location = a.int("location_id")
            for _ in 0..<6 {
                guard let current = location, let parent = byItem[current] else { return false }
                if isAssembledShip(parent) { return true }
                location = parent.int("location_id")
            }
            return false
        }

        var stacks: [Stack: Int] = [:]
        var skippedShips = 0
        var skippedOre = 0
        for a in byItem.values {
            guard let typeID = a.int("type_id"), let t = info[typeID] else { continue }
            let flag = a.string("location_flag") ?? ""
            if notCargo.contains(flag) || fittedPrefixes.contains(where: { flag.hasPrefix($0) }) { continue }
            if isAssembledShip(a) { skippedShips += 1; continue }
            if insideShip(a) { continue }
            if a.bool("is_singleton"), let itemID = a.int("item_id"), parents.contains(itemID) { continue }
            let category = t.int("category_id")
            // Ore, compressed ore and ice belong on the Ore Reprocessing page.
            if category == Reprocessing.asteroidCategory {
                let root = Market.rootLocation(a, byItem)
                if locationID == 0 || root == locationID { skippedOre += 1 }
                continue
            }
            if category == blueprintCategory || category == skillCategory { continue }
            if t.dicts("materials").isEmpty { continue }
            let root = Market.rootLocation(a, byItem)
            if locationID != 0 && root != locationID { continue }
            stacks[Stack(typeID: typeID, location: root), default: 0] += a.int("quantity") ?? 1
        }
        return (stacks, skippedShips, skippedOre, info)
    }

    private static func volumes(_ ids: [Int]) throws -> [Int: Double] {
        guard !ids.isEmpty else { return [:] }
        var result: [Int: Double] = [:]
        for r in try SDE.connect().query(
            "SELECT type_id, volume, packaged_volume FROM types WHERE type_id IN (\(placeholders(ids.count)))", ids) {
            if let id = r.int("type_id") {
                let packaged = r.double("packaged_volume") ?? 0
                result[id] = packaged > 0 ? packaged : (r.double("volume") ?? 0)
            }
        }
        return result
    }

    static func hubList(_ sellHub: String) async throws -> [String] {
        if sellHub.lowercased() == "best" { return Market.hubStations.map { $0.0 } }
        return [try await Market.hub(sellHub).string("name") ?? sellHub]
    }

    // MARK: - Page: My Stuff

    /// at: "here" · "refinery" · "compare"
    static func summary(locationID: Int, at: String, sellHub: String, price: String, refineryID: Int,
                        settings: Reprocessing.Settings) async throws -> JSONDict {
        let (stacks, skippedShips, skippedOre, _) = try await ownedStacks(locationID: locationID)
        let hubs = try await hubList(sellHub)
        let useRefinery = refineryID != 0 && (at == "refinery" || at == "compare")
        let useHere = at == "here" || at == "compare" || refineryID == 0

        let roots = Array(Set(stacks.keys.map { $0.location }))
        var locationIDs = roots
        if refineryID != 0 { locationIDs.append(refineryID) }
        let resolved = await ESI.resolveLocations(locationIDs)
        func placeName(_ id: Int) -> String {
            let entry = resolved[String(id)] as? JSONDict
            return entry?.string("station") ?? entry?.string("name") ?? String(id)
        }

        let levels = try await Market.skillLevels()
        let standings = (try? await Market.standings()) ?? [:]
        var places: [Int: Place] = [:]
        for id in Set(locationIDs) {
            places[id] = try await place(id, name: placeName(id), refineryID: refineryID, settings: settings,
                                         levels: levels, standings: standings)
        }
        let refinery: Place? = refineryID != 0 ? places[refineryID] : nil

        let ctx = try await context(roots: Set(stacks.keys.map { $0.typeID }), hubs: hubs, price: price)
        let volume = try volumes(Array(Set(stacks.keys.map { $0.typeID })))

        // Jumps to the refinery from each other station (only when the refinery is in play).
        var jumps: [Int: Int] = [:]
        if useRefinery, let refinery {
            let target = await Hauling.systemOf(refinery.id)
            let others = roots.filter { $0 != refinery.id }
            let found = try await concurrentMap(others, limit: 4) { root -> Int? in
                await Hauling.route(from: root, toSystem: target)?.int("jumps")
            }
            for (root, j) in zip(others, found) { if let j { jumps[root] = j } }
        }

        var rows: [JSONDict] = []
        for (stack, quantity) in stacks {
            guard let here = places[stack.location] else { continue }
            var candidates: [Place] = []
            if useHere { candidates.append(here) }
            if useRefinery, let refinery, refinery.id != here.id { candidates.append(refinery) }
            if candidates.isEmpty { candidates.append(here) }
            let result = try best(stack.typeID, quantity, places: candidates, hubs: hubs, ctx)
            let node = result.node
            let call = verdict(asIs: node.asIs, reprocessed: node.reprocessed)
            let gain: Double? = node.reprocessed.map { $0 - (node.asIs ?? 0) }
            let gainPercent: Double? = (node.asIs ?? 0) > 0 ? gain.map { $0 / node.asIs! } : nil
            let hereValue: Double? = result.byPlace[here.id] ?? nil
            let refineryValue: Double? = refinery.flatMap { result.byPlace[$0.id] ?? nil }
            let m3: Double = (volume[stack.typeID] ?? 0) * Double(quantity)
            let jumpsAway: Int? = stack.location == refineryID ? 0 : jumps[stack.location]
            let groupName: String? = ctx.info[stack.typeID]?.string("group_name")
            let soldPerDay: Double? = node.check?.double("sold_per_day")
            let tree: JSONDict = node.json
            rows.append([
                "type_id": stack.typeID,
                "name": node.name,
                "group_name": groupName as Any,
                "quantity": quantity,
                "location_id": stack.location,
                "location": here.name,
                "as_is": node.asIs as Any,
                "reprocessed": node.reprocessed as Any,
                "best_value": node.value,
                "verdict": call,
                "gain": gain as Any,
                "gain_percent": gainPercent as Any,
                "hub": result.hub,
                "place": result.place.json,
                "reprocessed_here": hereValue as Any,
                "reprocessed_refinery": refineryValue as Any,
                "volume_m3": m3,
                "jumps_to_refinery": jumpsAway as Any,
                "sold_per_day": soldPerDay as Any,
                "check": node.check as Any,
                "tree": tree,
            ])
        }
        rows.sort { ($0.double("gain") ?? -.infinity) > ($1.double("gain") ?? -.infinity) }

        let totalAsIs = rows.reduce(0.0) { $0 + ($1.double("as_is") ?? 0) }
        let totalBest = rows.reduce(0.0) { $0 + ($1.double("best_value") ?? 0) }
        let reprocessCount = rows.filter { $0.string("verdict") == "reprocess" }.count
        let sellCount = rows.filter { ["sell", "either"].contains($0.string("verdict") ?? "") }.count
        let scrap = try Reprocessing.level(levels, "Scrapmetal Processing")
        return [
            "location_id": locationID,
            "at": useRefinery ? at : "here",
            "sell_hub": sellHub,
            "price": price,
            "rows": rows,
            "total_as_is": totalAsIs,
            "total_best": totalBest,
            "reprocess_count": reprocessCount,
            "sell_count": sellCount,
            "skipped_ships": skippedShips,
            "skipped_ore": skippedOre,
            "scrapmetal_level": scrap,
            "refinery": refinery?.json as Any,
            "no_refinery": refineryID == 0 && at != "here",
            "price_gaps": ctx.priceGaps,
            "lookback_days": ctx.fair.lookbackDays,
        ]
    }

    // MARK: - One item, all five hubs (detail pane / Look Up)

    /// One stack (or a looked-up item) at every hub. locationID 0 = Look Up: reprocessed at your refinery
    /// when one is set, else at a standard NPC station.
    static func item(typeID: Int, quantity: Int, locationID: Int, at: String, sellHub: String, price: String,
                     refineryID: Int, settings: Reprocessing.Settings) async throws -> JSONDict {
        let hubs = Market.hubStations.map { $0.0 }
        let levels = try await Market.skillLevels()
        let standings = (try? await Market.standings()) ?? [:]
        var ids = [locationID, refineryID].filter { $0 != 0 }
        ids = Array(Set(ids))
        let resolved = await ESI.resolveLocations(ids)
        func placeName(_ id: Int) -> String {
            let entry = resolved[String(id)] as? JSONDict
            return entry?.string("station") ?? entry?.string("name") ?? String(id)
        }

        var candidates: [Place] = []
        if locationID == 0 {
            if refineryID != 0 {
                let refinery = try await place(refineryID, name: placeName(refineryID), refineryID: refineryID,
                                               settings: settings, levels: levels, standings: standings)
                candidates.append(refinery)
            } else {
                candidates.append(plainStation)
            }
        } else {
            let here = try await place(locationID, name: placeName(locationID), refineryID: refineryID,
                                       settings: settings, levels: levels, standings: standings)
            if at == "here" || refineryID == 0 || at == "compare" { candidates.append(here) }
            if refineryID != 0 && refineryID != locationID && (at == "refinery" || at == "compare") {
                let refinery = try await place(refineryID, name: placeName(refineryID), refineryID: refineryID,
                                               settings: settings, levels: levels, standings: standings)
                candidates.append(refinery)
            }
            if candidates.isEmpty { candidates.append(here) }
        }

        if try SDE.typesInfo([typeID])[typeID]?.int("category_id") == Reprocessing.asteroidCategory {
            throw ValueError("Ore and ice are on the Ore Reprocessing page.")
        }
        let ctx = try await context(roots: [typeID], hubs: hubs, price: price)
        let quantity = max(quantity, 1)

        // Every hub, at the best of the candidate places.
        var grid: [JSONDict] = []
        var nodes: [String: Node] = [:]
        for hub in hubs {
            let r = try best(typeID, quantity, places: candidates, hubs: [hub], ctx)
            nodes[hub] = r.node
            grid.append([
                "hub": hub,
                "as_is": r.node.asIs as Any,
                "reprocessed": r.node.reprocessed as Any,
                "value": r.node.value,
                "verdict": verdict(asIs: r.node.asIs, reprocessed: r.node.reprocessed),
                "place": r.place.name,
            ])
        }

        // The answer for the page's own Sell at choice.
        let chosenHubs = try await hubList(sellHub)
        let chosen = try best(typeID, quantity, places: candidates, hubs: chosenHubs, ctx)

        // Selling each piece wherever it pays most (first level), for the "splitting would earn more" note.
        var split: Double?
        if chosen.node.reprocessed != nil, !chosen.node.outputs.isEmpty {
            var total = -chosen.node.tax
            for out in chosen.node.outputs {
                let values: [Double] = hubs.compactMap { h -> Double? in
                    nodes[h]?.outputs.first(where: { $0.typeID == out.typeID })?.value
                }
                total += values.max() ?? out.value
            }
            split = total
        }

        let node = chosen.node
        let scrap = try Reprocessing.level(levels, "Scrapmetal Processing")
        return [
            "type_id": typeID,
            "name": node.name,
            "quantity": quantity,
            "hub": chosen.hub,
            "place": chosen.place.json,
            "as_is": node.asIs as Any,
            "reprocessed": node.reprocessed as Any,
            "best_value": node.value,
            "verdict": verdict(asIs: node.asIs, reprocessed: node.reprocessed),
            "tree": node.json,
            "hubs": grid,
            "split_value": split as Any,
            "scrapmetal_level": scrap,
            "lookback_days": ctx.fair.lookbackDays,
        ]
    }

    // MARK: - Look Up search

    /// Names of published items that reprocess into something, matching what's typed.
    static func suggest(_ text: String) throws -> [String] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return try SDE.connect().query("""
            SELECT t.name FROM types t
            WHERE t.published = 1 AND t.name LIKE ? AND t.category_id <> \(Reprocessing.asteroidCategory)
              AND EXISTS (SELECT 1 FROM type_materials m WHERE m.type_id = t.type_id)
            ORDER BY (t.name LIKE ?) DESC, length(t.name), t.name
            LIMIT 12
            """, ["%\(q)%", "\(q)%"]).compactMap { $0.string("name") }
    }

    static func typeID(named name: String) throws -> Int? {
        try SDE.connect().query("SELECT type_id FROM types WHERE name = ? COLLATE NOCASE AND published = 1 LIMIT 1",
                                [name]).first?.int("type_id")
    }
}
