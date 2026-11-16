import Foundation

/// Originally `industry_calc.py` – manufacturing cost / time / profit calculator.
///
///   materials per job = max(runs, ceil(round(runs * base * ME_mod * struct_mod * rig_mod, 2)))
///   job time          = base * runs * (1-TE) * (1-4%*Industry) * (1-3%*Adv Industry) * struct * rig
///   job fee           = EIV * (SCI * (1 - struct fee bonus) + facility tax + SCC 4%)
///                       EIV = runs * sum(base qty * CCP adjusted price)
///   sales tax         = 7.5% * (1 - 11% * Accounting)
///   broker fee (NPC)  = 3% - 0.3%*Broker Relations - 0.03%*faction - 0.02%*corp standing (min 1%)
enum IndustryCalc {
    static let sccSurcharge = 0.04
    static let npcFacilityTax = 0.0025

    /// Upwell engineering complexes: (material bonus, time bonus, job-fee bonus)
    static let structures: [String: (me: Double, te: Double, fee: Double)] = [
        "npc": (0.0, 0.0, 0.0),
        "raitaru": (0.01, 0.15, 0.03),
        "azbel": (0.01, 0.20, 0.04),
        "sotiyo": (0.01, 0.30, 0.05),
    ]

    /// Required skills that don't give the 1%/level science bonus.
    static let noTimeBonusSkills: Set<String> = ["Industry", "Advanced Industry"]

    static func skillLevel(_ levels: [Int: Int], _ name: String) throws -> Int {
        try Reprocessing.level(levels, name)
    }

    static func brokerFee(_ levels: [Int: Int], _ hubInfo: JSONDict, _ standingMap: [String: Double]) throws -> Double {
        let brokerRelations = Double(try skillLevel(levels, "Broker Relations"))
        let faction = standingMap[Market.standingKey("faction", hubInfo.int("owner_faction_id"))] ?? 0.0
        let corp = standingMap[Market.standingKey("npc_corp", hubInfo.int("owner_corporation_id"))] ?? 0.0
        let fee = 0.03 - 0.003 * brokerRelations - 0.0003 * faction - 0.0002 * corp
        return max(fee, 0.01)
    }

    /// As before: math.ceil(round(x, 2))
    static func ceilRounded(_ x: Double) -> Int {
        Int(((x * 100).rounded(.toNearestOrEven) / 100).rounded(.up))
    }

    static func calculate(
        blueprintTypeID: Int,
        runs runsIn: Int = 1,
        me: Int = 0,
        te: Int = 0,
        systemID: Int? = nil,
        structure: String = "npc",
        rigME: Double = 0.0,
        rigTE: Double = 0.0,
        facilityTax facilityTaxIn: Double? = nil,
        materialHub: String = "Jita",
        materialPrice: String = "sell",
        useOwned: Bool = true,
        stockLocation: Int? = nil,
        refineryLocation: Int? = nil,
        refinery: Reprocessing.Settings? = nil
    ) async throws -> JSONDict {
        let runs = max(1, runsIn)
        guard let data = try SDE.manufacturing(blueprintTypeID) else {
            throw ValueError("Blueprint \(blueprintTypeID) has no manufacturing activity")
        }

        let bp = data.dict("blueprint") ?? [:]
        let bonuses = structures[structure] ?? structures["npc"]!
        let facilityTax = facilityTaxIn ?? (structure == "npc" ? npcFacilityTax * 100 : 0.0)

        let levels = try await Market.skillLevels()
        var warnings: [String] = []

        // ---------------- Materials ----------------
        let materialMod = (1 - Double(me) / 100) * (1 - bonuses.me) * (1 - rigME / 100)
        let bpMaterials = data.dicts("materials")
        let materialIDs = bpMaterials.compactMap { $0.int("material_type_id") }

        let books = try await Market.hubBooks(materialHub, materialIDs)
        let adjusted = try await Market.adjustedPrices()
        var owned: [Int: Int] = [:]
        if useOwned {
            do {
                owned = try await Market.ownedQuantities(stockLocation)
            } catch {
                warnings.append("Couldn't read your assets: \(error.localizedDescription)")
            }
        }

        // Ore waiting at the refinery counts as the minerals it would reprocess into.
        var fromOre: [Int: Int] = [:]
        if useOwned, let refineryLocation, refineryLocation != 0 {
            do {
                fromOre = try await Reprocessing.mineralsFromOre(refineryLocation, refinery ?? Reprocessing.Settings(), levels)
            } catch {
                warnings.append("Couldn't work out minerals from your ore: \(error.localizedDescription)")
            }
        }

        var materials: [JSONDict] = []
        var materialCost = 0.0
        var cashCost = 0.0
        var eiv = 0.0
        for m in bpMaterials {
            let typeID = m.int("material_type_id") ?? 0
            let base = m.int("quantity") ?? 0
            let required = max(runs, ceilRounded(Double(runs) * Double(base) * materialMod))
            var priceSource = "\(materialHub) \(materialPrice) orders"
            var unit: Double
            if let price = books[typeID]?.double(materialPrice) {
                unit = price
            } else {
                unit = adjusted[typeID] ?? 0.0
                priceSource = "CCP adjusted price (no orders at hub)"
            }
            let have = owned[typeID] ?? 0
            let oreMinerals = fromOre[typeID] ?? 0
            let toBuy = max(0, required - have - oreMinerals)

            let total = Double(required) * unit
            materialCost += total
            cashCost += Double(toBuy) * unit
            eiv += Double(base * runs) * (adjusted[typeID] ?? 0.0)

            let buyCost: Double = Double(toBuy) * unit
            let volume: Double = (m.double("volume") ?? 0) * Double(toBuy)
            let baseQuantity: Int = base * runs
            materials.append([
                "type_id": typeID,
                "name": m.string("name") as Any,
                "base_quantity": baseQuantity,
                "required": required,
                "owned": have,
                "from_ore": oreMinerals,
                "to_buy": toBuy,
                "unit_price": unit,
                "total_value": total,
                "buy_cost": buyCost,
                "price_source": priceSource,
                "volume_m3": volume,
            ])
        }

        // ---------------- Time ----------------
        let industry = try skillLevel(levels, "Industry")
        let advanced = try skillLevel(levels, "Advanced Industry")
        var scienceMod = 1.0
        for skill in data.dicts("skills") {
            // T2 blueprints list science / advanced construction skills: 1% faster per level.
            if !noTimeBonusSkills.contains(skill.string("name") ?? "") {
                scienceMod *= 1 - 0.01 * Double(levels[skill.int("skill_type_id") ?? 0] ?? 0)
            }
        }

        let timeMod = (1 - Double(te) / 100) * (1 - 0.04 * Double(industry)) * (1 - 0.03 * Double(advanced))
            * (1 - bonuses.te) * (1 - rigTE / 100) * scienceMod
        let baseTime = bp.int("time") ?? 0
        let jobSeconds = Double(baseTime * runs) * timeMod

        // ---------------- Job fee ----------------
        var costIndex = 0.0
        var systemInfo: JSONDict?
        if let systemID, systemID != 0 {
            systemInfo = try SDE.system(systemID)
            costIndex = try await Market.costIndices()[systemID]?["manufacturing"] ?? 0.0
            if costIndex == 0.0 {
                warnings.append("No manufacturing cost index for that system (no recent industry there).")
            }
        } else {
            warnings.append("No build system chosen – system cost index treated as 0%.")
        }

        let feeRate = costIndex * (1 - bonuses.fee) + facilityTax / 100 + sccSurcharge
        let jobFee = eiv * feeRate

        // ---------------- Selling at every hub ----------------
        let productID = bp.int("product_type_id") ?? 0
        let productQty = (bp.int("product_quantity") ?? 1) * runs
        let accounting = try skillLevel(levels, "Accounting")
        let salesTax = 0.075 * (1 - 0.11 * Double(accounting))

        var standingMap: [String: Double] = [:]
        do {
            standingMap = try await Market.standings()
        } catch {
            warnings.append("Couldn't read standings – broker fees assume 0 standing.")
        }

        let hours = jobSeconds != 0 ? jobSeconds / 3600 : 0
        let productBooks = try await Market.allHubBooks(productID)

        func outcome(_ price: Double?, _ feeRateTotal: Double) -> JSONDict? {
            guard let price else { return nil }
            let gross = price * Double(productQty)
            let fees = gross * feeRateTotal
            let net = gross - fees
            let profitMarket = net - materialCost - jobFee
            let profitCash = net - cashCost - jobFee
            let costBasis = materialCost + jobFee
            let margin: Double? = costBasis != 0 ? profitMarket / costBasis : nil
            let iskPerHour: Double? = hours != 0 ? profitMarket / hours : nil
            let cashMargin: Double? = gross != 0 ? profitCash / gross : nil
            let cashIskPerHour: Double? = hours != 0 ? profitCash / hours : nil
            return [
                "unit_price": price,
                "gross": gross,
                "fees": fees,
                "net": net,
                "profit": profitMarket,
                "profit_cash": profitCash,
                "margin": margin as Any,
                "isk_per_hour": iskPerHour as Any,
                // Cash view (materials you own are free) – what the app's hub table shows.
                "cash_margin": cashMargin as Any,
                "cash_isk_per_hour": cashIskPerHour as Any,
            ]
        }

        // Prices go through FairPrice: averaged over the orders that would cover the whole
        // batch, checked against the region's median and capped when they look inflated.
        let fairSettings = FairPrice.Settings.current
        var hubsOut: [JSONDict] = []
        for hubInfo in try await Market.hubs() {
            let name = hubInfo.string("name") ?? ""
            let book = productBooks[name] ?? [:]
            let broker = try brokerFee(levels, hubInfo, standingMap)
            let history: JSONDict? = try? await Market.hubHistory(name, productID, days: fairSettings.lookbackDays)
            let sellLive: Double? = FairPrice.sellDepthPrice(book, quantity: productQty) ?? book.double("sell")
            let buyLive: Double? = FairPrice.buyDepthPrice(book, quantity: productQty) ?? book.double("buy")
            let sellCheck = FairPrice.check(live: sellLive, history: history, quantity: productQty, settings: fairSettings)
            let buyCheck = FairPrice.check(live: buyLive, history: history, quantity: productQty, settings: fairSettings)
            let sellUsed: Double? = sellCheck.double("used")
            let buyUsed: Double? = buyCheck.double("used")
            let sellOrder: JSONDict? = outcome(sellUsed, broker + salesTax) // list a sell order
            let instant: JSONDict? = outcome(buyUsed, salesTax)             // sell into buy orders
            let trend: JSONDict? = await HistoryStore.shared.competitionTrend(hub: name, typeID: productID)
            let spread: String? = FairPrice.spread(book)
            hubsOut.append([
                "hub": name,
                "lowest_sell": book.double("sell") as Any,
                "best_buy": book.double("buy") as Any,
                "sell_check": sellCheck,
                "buy_check": buyCheck,
                "spread": spread as Any,
                "lookback_days": fairSettings.lookbackDays,
                "station_name": hubInfo.string("station_name") as Any,
                "broker_fee": broker,
                "sales_tax": salesTax,
                "sell_order": sellOrder as Any,
                "instant": instant as Any,
                "sell_orders": book.int("sell_orders") ?? 0,
                "sell_volume": book.int("sell_volume") ?? 0,
                "buy_orders": book.int("buy_orders") ?? 0,
                "buy_volume": book.int("buy_volume") ?? 0,
                "trend": trend as Any,
            ])
        }

        func bestProfit(_ h: JSONDict) -> Double {
            h.dict("sell_order")?.double("profit_cash") ?? -Double.infinity
        }
        // max(): first of equal values wins.
        var best: JSONDict?
        for h in hubsOut where best == nil || bestProfit(h) > bestProfit(best!) { best = h }

        let bestHub: String? = best.flatMap { bestProfit($0) != -Double.infinity ? $0.string("hub") : nil }
        let totalCost: Double = materialCost + jobFee
        let totalCashCost: Double = cashCost + jobFee
        let baseSeconds: Int = baseTime * runs
        let facilityRate: Double = facilityTax / 100
        let time: JSONDict = [
            "base_seconds": baseSeconds,
            "seconds": jobSeconds,
            "industry_level": industry,
            "advanced_industry_level": advanced,
            "modifier": timeMod,
        ]
        let job: JSONDict = [
            "system": systemInfo as Any,
            "cost_index": costIndex,
            "estimated_item_value": eiv,
            "facility_tax": facilityRate,
            "scc_surcharge": sccSurcharge,
            "structure": structure,
            "fee_rate": feeRate,
            "fee": jobFee,
        ]
        return [
            "blueprint_type_id": blueprintTypeID,
            "blueprint_name": bp.string("blueprint_name") as Any,
            "product_type_id": productID,
            "product_name": bp.string("product_name") as Any,
            "group_name": bp.string("group_name") as Any,
            "runs": runs,
            "product_quantity": productQty,
            "me": me,
            "te": te,
            "materials": materials,
            "material_cost": materialCost,
            "cash_cost": cashCost,
            "material_hub": materialHub,
            "material_price": materialPrice,
            "stock_location": stockLocation as Any,
            "time": time,
            "job": job,
            "total_cost": totalCost,
            "total_cash_cost": totalCashCost,
            "hubs": hubsOut,
            "best_hub": bestHub as Any,
            "accounting_level": accounting,
            "warnings": warnings,
        ]
    }
}
