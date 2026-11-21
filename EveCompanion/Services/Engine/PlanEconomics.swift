import Foundation

/// Build Planner money (19 Nov 2026, user): what the plan costs, what it sells for, the profit.
/// Valued the same way as Build vs Sell:
/// - minerals (mined or already in stock) at what they'd fetch in the hub's buy orders after
///   sales tax – so the profit says whether building beats just selling the minerals;
/// - anything else at the hub's cheapest sell order (what you'd pay);
/// - components either built (their own materials + their job fee) or bought, per the toggle;
/// - job fees from CCP's adjusted prices, your build system's cost index and structure.
/// Products sell at the Build vs Sell sell hub ("best" = best of the five), price-checked
/// against history, after broker fee and sales tax.
enum PlanEconomics {
    struct Cost {
        var minerals = 0.0
        var bought = 0.0
        var fees = 0.0
        var total: Double { minerals + bought + fees }
        var materials: Double { minerals + bought }
        static func + (a: Cost, b: Cost) -> Cost {
            Cost(minerals: a.minerals + b.minerals, bought: a.bought + b.bought, fees: a.fees + b.fees)
        }
        func scaled(_ f: Double) -> Cost { Cost(minerals: minerals * f, bought: bought * f, fees: fees * f) }
    }

    private struct Recipe {
        let blueprintID: Int
        let productID: Int
        let perRun: Int
        let materials: [(type: Int, quantity: Int)]
    }

    static func work(items: [Mining.PlanItem], mineable: Set<Int>, bestME: [Int: Int], componentRuns: [Int: Int],
                     breakDown: Bool, structure: String, rigME: Double, systemID: Int?, facilityTax facilityTaxIn: Double?,
                     materialHub: String, sellHub: String, mineralsToMine: [Int: Int],
                     needed: [Int: Int] = [:], have: [Int: Int] = [:],
                     boughtStock: [Int: (qty: Double, cost: Double)] = [:],
                     toBuy: [Int: Int] = [:],
                     freeSplit: [Int: StockOrigin.Split] = [:]) async throws -> JSONDict {
        let bonuses = IndustryCalc.structures[structure] ?? IndustryCalc.structures["npc"]!
        let facilityTax = facilityTaxIn ?? (structure == "npc" ? IndustryCalc.npcFacilityTax * 100 : 0.0)
        let levels = try await Market.skillLevels()
        let standingMap = (try? await Market.standings()) ?? [:]
        let accounting = Double(try IndustryCalc.skillLevel(levels, "Accounting"))
        let salesTax = 0.075 * (1 - 0.11 * accounting)
        let adjusted = try await Market.adjustedPrices()
        let averages = (try? await Market.averagePrices()) ?? [:]
        var costIndex = 0.0
        if let systemID, systemID != 0 {
            costIndex = (try? await Market.costIndices())?[systemID]?["manufacturing"] ?? 0.0
        }
        let feeRate = costIndex * (1 - bonuses.fee) + facilityTax / 100 + IndustryCalc.sccSurcharge

        // ---- Recipes: the items and every component below them ----
        let db = try SDE.connect()
        let byProduct = try db.prepare("""
            SELECT m.blueprint_type_id, m.product_quantity FROM bp_manufacturing m
            JOIN types b ON b.type_id = m.blueprint_type_id
            WHERE m.product_type_id = ? AND b.published = 1 LIMIT 1
            """)
        func recipe(blueprint bpID: Int) throws -> Recipe? {
            guard let data = try SDE.manufacturing(bpID) else { return nil }
            let bp = data.dict("blueprint") ?? [:]
            let perRun = max(1, bp.int("product_quantity") ?? 1)
            let mats = data.dicts("materials").map { (type: $0.int("material_type_id") ?? 0, quantity: $0.int("quantity") ?? 0) }
            return Recipe(blueprintID: bpID, productID: bp.int("product_type_id") ?? 0, perRun: perRun, materials: mats)
        }
        var itemRecipes: [Int: Recipe] = [:]          // blueprint id → recipe
        var componentRecipes: [Int: Recipe] = [:]     // product type id → recipe
        var allTypes = Set<Int>()
        var queue: [Int] = []
        var seen = Set<Int>()
        for item in items {
            guard let r = try recipe(blueprint: item.blueprintTypeID) else { continue }
            itemRecipes[item.blueprintTypeID] = r
            for m in r.materials { allTypes.insert(m.type); queue.append(m.type) }
        }
        var guardCount = 0
        while !queue.isEmpty, guardCount < 2000 {
            guardCount += 1
            let type = queue.removeFirst()
            guard !seen.contains(type), !mineable.contains(type) else { continue }
            seen.insert(type)
            guard let row = try byProduct.rows([type]).first, let bpID = row.int("blueprint_type_id"),
                  let r = try recipe(blueprint: bpID) else { continue }
            componentRecipes[type] = r
            for m in r.materials {
                allTypes.insert(m.type)
                if !seen.contains(m.type) { queue.append(m.type) }
            }
        }

        // ---- Material prices at the material hub ----
        let fetch = try await Market.hubBooksAllowingGaps(materialHub, allTypes)
        func fallback(_ id: Int) -> Double? { averages[id].flatMap { $0 > 0 ? $0 : nil } }
        func mineralValue(_ id: Int) -> Double {
            let price: Double = fetch.books[id]?.double("buy") ?? fallback(id) ?? 0
            return price * (1 - salesTax)
        }
        func buyPrice(_ id: Int) -> Double {
            fetch.books[id]?.double("sell") ?? fallback(id) ?? 0
        }
        func required(_ runs: Int, _ quantity: Int, _ me: Int) -> Int {
            let mod = (1 - Double(me) / 100) * (1 - bonuses.me) * (1 - rigME / 100)
            return max(runs, IndustryCalc.ceilRounded(Double(runs * quantity) * mod))
        }
        func jobFee(_ r: Recipe, _ runs: Int) -> Double {
            var eiv = 0.0
            for m in r.materials { eiv += Double(m.quantity * runs) * (adjusted[m.type] ?? 0) }
            return eiv * feeRate
        }

        // ---- Unit cost of anything, built or bought ----
        var memo: [Bool: [Int: Cost]] = [true: [:], false: [:]]
        var visiting = Set<Int>()
        func unitCost(_ type: Int, build: Bool) -> Cost {
            if let known = memo[build]?[type] { return known }
            var result: Cost
            if mineable.contains(type) {
                result = Cost(minerals: mineralValue(type))
            } else if build, let r = componentRecipes[type], !visiting.contains(type) {
                visiting.insert(type)
                let runs = max(1, componentRuns[type] ?? 1)
                let me = bestME[r.blueprintID] ?? 0
                var total = Cost(fees: jobFee(r, runs))
                for m in r.materials {
                    let qty = Double(required(runs, m.quantity, me))
                    total = total + unitCost(m.type, build: true).scaled(qty)
                }
                visiting.remove(type)
                result = total.scaled(1 / Double(runs * r.perRun))
            } else {
                result = Cost(bought: buyPrice(type))
            }
            memo[build, default: [:]][type] = result
            return result
        }
        func itemCost(_ item: Mining.PlanItem, build: Bool) -> Cost? {
            guard let r = itemRecipes[item.blueprintTypeID] else { return nil }
            let me = bestME[item.blueprintTypeID] ?? 0
            var total = Cost(fees: jobFee(r, item.runs))
            for m in r.materials {
                let qty = Double(required(item.runs, m.quantity, me))
                total = total + unitCost(m.type, build: build).scaled(qty)
            }
            return total
        }

        // ---- What the products sell for ----
        let allHubs = try await Market.hubs()
        var brokers: [String: Double] = [:]
        for h in allHubs {
            brokers[h.string("name") ?? ""] = try IndustryCalc.brokerFee(levels, h, standingMap)
        }
        let sellHubs: [String]
        if !sellHub.isEmpty, sellHub.lowercased() != "best" {
            sellHubs = [try await Market.hub(sellHub).string("name") ?? sellHub]
        } else {
            sellHubs = allHubs.compactMap { $0.string("name") }
        }
        let fairSettings = FairPrice.Settings.current

        struct Sale { let hub: String; let net: Double; let unitPrice: Double; let status: String? }
        func sale(productID: Int, units: Int) async -> Sale? {
            // First pick by the live price, then check that hub's price against its history.
            var first: (hub: String, live: Double, net: Double)?
            for hub in sellHubs {
                guard let book = try? await Market.hubBook(hub, productID),
                      let live = FairPrice.sellDepthPrice(book, quantity: units) ?? book.double("sell") else { continue }
                let net = live * Double(units) * (1 - (brokers[hub] ?? 0) - salesTax)
                if first == nil || net > first!.net { first = (hub, live, net) }
            }
            guard let first else { return nil }
            let history = try? await Market.hubHistory(first.hub, productID, days: fairSettings.lookbackDays)
            let checked = FairPrice.check(live: first.live, history: history, quantity: units, settings: fairSettings)
            let used: Double = checked.double("used") ?? first.live
            let net = used * Double(units) * (1 - (brokers[first.hub] ?? 0) - salesTax)
            return Sale(hub: first.hub, net: net, unitPrice: used, status: checked.string("status"))
        }

        // ---- Per item and totals ----
        var rows: [JSONDict] = []
        var cost = Cost()
        var otherWayCost = 0.0
        var sells = 0.0
        var unsold: [String] = []
        for item in items {
            guard let r = itemRecipes[item.blueprintTypeID], let c = itemCost(item, build: breakDown) else { continue }
            let other = itemCost(item, build: !breakDown)?.total ?? c.total
            let productID = r.productID
            let units = item.runs * r.perRun
            let s = await sale(productID: productID, units: units)
            cost = cost + c
            otherWayCost += other
            var row: JSONDict = [
                "blueprint_type_id": item.blueprintTypeID,
                "cost": c.total, "cost_minerals": c.minerals, "cost_bought": c.bought, "cost_fees": c.fees,
            ]
            if let s {
                let profit = s.net - c.total
                sells += s.net
                row["sells_for"] = s.net
                row["sell_hub"] = s.hub
                row["unit_price"] = s.unitPrice
                row["price_status"] = s.status as Any
                row["profit"] = profit
                if c.materials > 0 { row["profit_percent"] = profit / c.materials }
            } else {
                unsold.append(String(productID))
            }
            rows.append(row)
        }

        var minedValue = 0.0
        for (type, qty) in mineralsToMine { minedValue += Double(qty) * mineralValue(type) }

        // ---- Anything taken from stock: bought / built (what it cost you) or free ----
        // Minerals, components and parts alike. The stock pool (same one as Manufacturing's
        // Track Record) holds what you bought – or built, at what the build cost you – and still
        // have, at average cost. Stock it doesn't cover was mined, looted or already there: free.
        var stockBoughtUnits = 0.0, stockBoughtValue = 0.0, stockPaid = 0.0
        var stockFreeUnits = 0.0, stockFreeValue = 0.0
        var stockMinedValue = 0.0, stockOtherValue = 0.0, stockHadValue = 0.0
        for (type, need) in needed where need > 0 {
            let used = Double(min(have[type] ?? 0, need))
            guard used > 0 else { continue }
            let pool = boughtStock[type] ?? (0, 0)
            let fromBought = min(used, max(0, pool.qty))
            let value = mineable.contains(type) ? mineralValue(type) : buyPrice(type)
            if fromBought > 0 {
                stockBoughtUnits += fromBought
                stockBoughtValue += fromBought * value
                stockPaid += pool.qty > 0 ? pool.cost / pool.qty * fromBought : 0
            }
            stockFreeUnits += used - fromBought
            stockFreeValue += (used - fromBought) * value
            // Free part: mined · other source (loot, salvage…) · already had. Unknown → already had.
            let split = freeSplit[type] ?? StockOrigin.Split(mined: 0, other: 0, had: 1)
            let free = (used - fromBought) * value
            stockMinedValue += free * split.mined
            stockOtherValue += free * split.other
            stockHadValue += free * split.had
        }
        // Cash: only ISK you actually spend – what's still to buy (at the hub), the job fees of the
        // jobs you'll run (items + components still to build), and what your stock cost you.
        // Minerals you mine, and stock you mined, looted or already had, cost no ISK.
        var cashToBuy = 0.0
        for (type, qty) in toBuy where qty > 0 { cashToBuy += Double(qty) * buyPrice(type) }
        var cashFees = 0.0
        for item in items {
            if let r = itemRecipes[item.blueprintTypeID] { cashFees += jobFee(r, item.runs) }
        }
        if breakDown {
            for (type, runs) in componentRuns where runs > 0 {
                if let r = componentRecipes[type] { cashFees += jobFee(r, runs) }
            }
        }
        let cashCost: Double = cashToBuy + cashFees + stockPaid
        let hasComponents = !componentRecipes.isEmpty
        // Positive = building the components yourself is cheaper than buying them.
        let buildingSaves: Double = breakDown ? otherWayCost - cost.total : cost.total - otherWayCost

        var out: JSONDict = [
            "items": rows,
            "cost": cost.total, "cost_minerals": cost.minerals, "cost_bought": cost.bought, "cost_fees": cost.fees,
            "sell_hub_setting": sellHub,
            "unsold_count": unsold.count,
            "mined_minerals_value": minedValue,
            "stock_bought_units": stockBoughtUnits, "stock_bought_value": stockBoughtValue, "stock_paid": stockPaid,
            "stock_free_units": stockFreeUnits, "stock_free_value": stockFreeValue,
            "stock_mined_value": stockMinedValue, "stock_other_value": stockOtherValue, "stock_had_value": stockHadValue,
            "cash_cost": cashCost,
        ]
        if unsold.isEmpty {
            let profit = sells - cost.total
            out["sells_for"] = sells
            out["profit"] = profit
            if cost.materials > 0 { out["profit_percent"] = profit / cost.materials }
            out["profit_if_mined_free"] = profit + minedValue
            out["cash_profit"] = sells - cashCost
        }
        if hasComponents { out["building_components_saves"] = buildingSaves }
        return out
    }
}
