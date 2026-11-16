import Foundation

/// Build › Blueprint Copying: is making copies of a blueprint original to sell on contracts worth it?
/// Every copyable original sold on the market (narrowed like Build vs Sell), yours marked.
///
///   copy time per run = blueprint copy time × (1 − 5% × Science) × (1 − 3% × Advanced Industry)
///                       × (1 − structure time bonus)
///   copy fee per run  = EIV × 2% × (copying cost index × (1 − structure fee bonus) + facility tax + SCC 4%)
///                       EIV = Σ base materials (ME 0) × CCP adjusted price
///   contract price    = public contracts in the hub's region selling exactly one copy, per run
///                       (median of what probably sold within the History range once 3+ have, else asking prices)
///   margin per run    = typical contract price per run − copy fee per run
///   ISK per lab hour  = margin per run ÷ copy hours per run
/// Selling on contracts has no sales tax; the small contract listing fee isn't included.
enum Copying {
    /// Minimum offers before the typical price is trusted.
    static let minimumOffers = 3

    static func compare(hub: String, systemID: Int?, structure: String, facilityTax facilityTaxIn: Double?,
                        runsPerCopy: Int?, copies: Int, category: String = "", group: String = "",
                        search: String = "", ownedOnly: Bool = false) async throws -> JSONDict {
        let bonuses = IndustryCalc.structures[structure] ?? IndustryCalc.structures["npc"]!
        let facilityTax = facilityTaxIn ?? (structure == "npc" ? IndustryCalc.npcFacilityTax * 100 : 0.0)
        let levels = try await Market.skillLevels()
        let science = Double(try IndustryCalc.skillLevel(levels, "Science"))
        let advanced = Double(try IndustryCalc.skillLevel(levels, "Advanced Industry"))
        let labOperation = try IndustryCalc.skillLevel(levels, "Laboratory Operation")
        let advancedLab = (try? IndustryCalc.skillLevel(levels, "Advanced Laboratory Operation")) ?? 0
        let labSlots: Int = 1 + labOperation + advancedLab

        var copyIndex = 0.0
        if let systemID, systemID != 0 {
            copyIndex = try await Market.costIndices()[systemID]?["copying"] ?? 0.0
        }
        let feeRate: Double = copyIndex * (1 - bonuses.fee) + facilityTax / 100 + IndustryCalc.sccSurcharge

        // Your originals (copies can't be copied).
        let blueprints = try await ESI.characterBlueprints()
        var originals: [Int: JSONDict] = [:]
        for bp in blueprints where bp.int("quantity") != -2 && (bp.int("runs") ?? -1) == -1 {
            guard let typeID = bp.int("type_id") else { continue }
            let me = bp.int("material_efficiency") ?? 0
            if let current = originals[typeID], (current.int("material_efficiency") ?? 0) >= me { continue }
            originals[typeID] = bp
        }

        let hubInfo = try await Market.hub(hub)
        let regionID = hubInfo.int("region_id") ?? 0
        let offers = try await Contracts.copyOffers(regionID: regionID)
        let adjusted = try await Market.adjustedPrices()
        let salesWindow = HistoryRange.days   // the app-wide History range (0 = All)
        let tracked = await Contracts.copySales(regionID: regionID, days: salesWindow)

        let db = try SDE.connect()

        // Every blueprint original sold on the market that can be copied (plus any you own),
        // narrowed by category / group / search like Build vs Sell.
        let ownedList = originals.keys.map(String.init).joined(separator: ",")
        let ownedSQL = ownedList.isEmpty ? "-1" : ownedList
        var whereParts = ["m.copy_time > 0", "p.published = 1", "b.published = 1",
                          "(b.market_group_id IS NOT NULL OR m.blueprint_type_id IN (\(ownedSQL)))"]
        var params: [Any?] = []
        if !category.isEmpty { whereParts.append("c.name = ?"); params.append(category) }
        if !group.isEmpty { whereParts.append("g.name = ?"); params.append(group) }
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            whereParts.append("(p.name LIKE ? OR b.name LIKE ?)")
            params += ["%\(trimmed)%", "%\(trimmed)%"]
        }
        if ownedOnly { whereParts.append("m.blueprint_type_id IN (\(ownedSQL))") }
        let candidates = try db.query("""
            SELECT m.blueprint_type_id FROM bp_manufacturing m
            JOIN types p ON p.type_id = m.product_type_id
            JOIN types b ON b.type_id = m.blueprint_type_id
            JOIN groups g ON g.group_id = p.group_id
            JOIN categories c ON c.category_id = p.category_id
            WHERE \(whereParts.joined(separator: " AND "))
            """, params).compactMap { $0.int("blueprint_type_id") }
        let regionName: String = (try db.query("SELECT region_name FROM solar_systems WHERE region_id = ? LIMIT 1",
                                               [regionID]).first?.string("region_name")) ?? "the region"
        let bpQuery = try db.prepare("""
            SELECT m.*, p.name AS product_name, b.name AS blueprint_name
            FROM bp_manufacturing m
            JOIN types p ON p.type_id = m.product_type_id
            JOIN types b ON b.type_id = m.blueprint_type_id
            WHERE m.blueprint_type_id = ?
            """)
        let materialQuery = try db.prepare(
            "SELECT material_type_id, quantity FROM bp_materials WHERE blueprint_type_id = ?")

        // Group name per blueprint (for the Item tooltip).
        var groupNames: [Int: String] = [:]
        if !candidates.isEmpty {
            let list = candidates.map(String.init).joined(separator: ",")
            for r in try db.query("""
                SELECT m.blueprint_type_id, g.name AS group_name FROM bp_manufacturing m
                JOIN types p ON p.type_id = m.product_type_id JOIN groups g ON g.group_id = p.group_id
                WHERE m.blueprint_type_id IN (\(list))
                """) {
                if let id = r.int("blueprint_type_id") { groupNames[id] = r.string("group_name") }
            }
        }

        var rows: [JSONDict] = []
        for typeID in candidates {
            let original: JSONDict? = originals[typeID]
            guard let bp = try bpQuery.rows([typeID]).first else { continue }
            let maxRuns = bp.int("max_runs") ?? 1
            let runs = max(1, min(runsPerCopy ?? maxRuns, maxRuns))
            let baseCopy = Double(bp.int("copy_time") ?? 0)
            let secondsPerRun: Double = baseCopy * (1 - 0.05 * science) * (1 - 0.03 * advanced) * (1 - bonuses.te)

            var eiv = 0.0
            for m in try materialQuery.rows([typeID]) {
                eiv += Double(m.int("quantity") ?? 0) * (adjusted[m.int("material_type_id") ?? 0] ?? 0)
            }
            let feePerRun: Double = eiv * 0.02 * feeRate

            // Contract prices per run; copies like yours (same ME or better) when there are enough.
            // Copies inherit the original's ME: compare with copies at least as good as yours.
            // Not owned → every offer counts.
            let myME = original?.int("material_efficiency") ?? 0
            let all = offers[typeID] ?? []
            let similar = original == nil ? all : all.filter { ($0.int("me") ?? 0) >= myME }
            let basis = similar.count >= minimumOffers ? similar : all
            let perRunPrices = basis.compactMap { $0.double("price_per_run") }
            let lowest: Double? = perRunPrices.min()
            let cheapest = basis.min { ($0.double("price_per_run") ?? 0) < ($1.double("price_per_run") ?? 0) }

            // What probably sold lately (tracked between scans) beats asking prices when we have it.
            let soldInfo: JSONDict? = tracked.sales[typeID]
            let probablySold: Int = soldInfo?.int("sold") ?? 0
            let soldPerRun: Double? = soldInfo?.double("median_per_run")
            let asking: Double? = Market.median(perRunPrices)
            let typical: Double? = probablySold >= minimumOffers ? (soldPerRun ?? asking) : (asking ?? soldPerRun)

            var marginPerRun: Double?
            var iskPerLabHour: Double?
            if let typical {
                marginPerRun = typical - feePerRun
                if secondsPerRun > 0, let marginPerRun { iskPerLabHour = marginPerRun / (secondsPerRun / 3600) }
            }
            let verdict: String
            if all.isEmpty && probablySold == 0 { verdict = "no_market" }
            else if all.count < minimumOffers && probablySold < minimumOffers { verdict = "thin" }
            else if (marginPerRun ?? 0) > 0 { verdict = "copy" }
            else { verdict = "not_worth" }

            let totalRuns = runs * max(1, copies)
            let totalSeconds: Double = secondsPerRun * Double(totalRuns)
            let totalFee: Double = feePerRun * Double(totalRuns)
            let totalValue: Double? = typical.map { $0 * Double(totalRuns) }
            let totalMargin: Double? = marginPerRun.map { $0 * Double(totalRuns) }
            rows.append([
                "blueprint_type_id": typeID,
                "product_type_id": bp.int("product_type_id") as Any,
                "name": bp.string("product_name") as Any,
                "group": groupNames[typeID] as Any,
                "blueprint_name": bp.string("blueprint_name") as Any,
                "owned": original != nil,
                "me": myME,
                "te": original?.int("time_efficiency") ?? 0,
                "max_runs": maxRuns,
                "runs_per_copy": runs,
                "copies": max(1, copies),
                "copy_seconds_per_run": secondsPerRun,
                "build_seconds_per_run": Double(bp.int("time") ?? 0),
                "fee_per_run": feePerRun,
                "offers": all.count,
                "probably_sold": probablySold,
                "sold_median_per_run": soldPerRun as Any,
                "similar_offers": similar.count,
                "typical_per_run": typical as Any,
                "lowest_per_run": lowest as Any,
                "cheapest_offer": cheapest as Any,
                "margin_per_run": marginPerRun as Any,
                "isk_per_lab_hour": iskPerLabHour as Any,
                "verdict": verdict,
                "total_seconds": totalSeconds,
                "total_fee": totalFee,
                "total_value": totalValue as Any,
                "total_margin": totalMargin as Any,
            ])
        }
        rows.sort { ($0.double("isk_per_lab_hour") ?? -.greatestFiniteMagnitude) > ($1.double("isk_per_lab_hour") ?? -.greatestFiniteMagnitude) }

        let offerCount: Int = offers.values.reduce(0) { $0 + $1.count }
        return [
            "hub": hubInfo.string("name") ?? hub,
            "region_id": regionID,
            "region_name": regionName,
            "copy_index": copyIndex,
            "fee_rate": feeRate,
            "science_level": Int(science),
            "advanced_industry_level": Int(advanced),
            "lab_slots": labSlots,
            "copy_offers_in_region": offerCount,
            "owned_originals": originals.count,
            "sales_window_days": salesWindow,
            "tracking_since": tracked.since as Any,
            "items": rows,
        ]
    }
}
