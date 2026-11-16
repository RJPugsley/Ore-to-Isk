import Foundation

/// Reference › Blueprint Payback: for blueprints you could buy, what one costs and how many runs
/// (and how much build time and market demand) it takes to earn that back.
///
///   blueprint price = lowest sell order at the buy hub (CCP base price if none)
///   gain per run    = Build vs Sell gain (sale − job fee − materials if sold), ME as chosen (new BPOs are ME 0)
///   runs to pay back = ceil(price / gain per run)
enum BlueprintPayback {
    static func compare(
        category: String, group: String, search: String, ownedBlueprints: [Int: BuildVsSell.Owned],
        hideOwned: Bool, assumeME: Int, systemID: Int?, structure: String, rigME: Double, rigTE: Double,
        facilityTax: Double?, materialHub: String, sellHub: String, buyHub: String, limit: Int, fresh: Bool
    ) async throws -> JSONDict {
        var result = try await BuildVsSell.compare(
            category: category, group: group, search: search, ownedOnly: false,
            ownedBlueprints: ownedBlueprints, defaultME: assumeME, defaultTE: 0,
            systemID: systemID, structure: structure, rigME: rigME, rigTE: rigTE,
            facilityTax: facilityTax, materialHub: materialHub, sellHub: sellHub, limit: limit, fresh: fresh)
        var items = result.dicts("items")
        if hideOwned { items = items.filter { !$0.bool("owned") } }

        // Which blueprints are on the market at all, and CCP's base price as a fallback.
        let blueprintIDs = Array(Set(items.compactMap { $0.int("blueprint_type_id") }))
        var marketable = Set<Int>()
        var basePrice: [Int: Double] = [:]
        if !blueprintIDs.isEmpty {
            for r in try SDE.connect().query(
                "SELECT type_id, market_group_id, base_price FROM types WHERE type_id IN (\(placeholders(blueprintIDs.count)))",
                blueprintIDs) {
                guard let id = r.int("type_id") else { continue }
                if r.int("market_group_id") != nil { marketable.insert(id) }
                if let price = r.double("base_price"), price > 0 { basePrice[id] = price }
            }
        }
        if fresh { try await Market.forgetBooks([buyHub], marketable) }
        let bookFetch = try await Market.hubBooksAllowingGaps(buyHub, marketable)
        let books = bookFetch.books
        let blueprintGaps = bookFetch.failed.count

        // Blueprint prices checked against their sales history. When buying, an inflated
        // listing is still what you'd pay, so the live price is kept – the flag warns you.
        let fairSettings = FairPrice.Settings.current
        let listedIDs = blueprintIDs.filter { marketable.contains($0) && books[$0]?.double("sell") != nil }
        let blueprintHistories = try await concurrentMap(listedIDs, limit: 16) { id -> JSONDict? in
            try? await Market.hubHistory(buyHub, id, days: fairSettings.lookbackDays)
        }
        var blueprintChecks: [Int: JSONDict] = [:]
        for (id, history) in zip(listedIDs, blueprintHistories) {
            var check = FairPrice.check(live: books[id]?.double("sell"), history: history, quantity: 1, settings: fairSettings)
            check["used"] = check["live"]
            check["thin"] = false
            check["speed"] = nil
            blueprintChecks[id] = check
        }

        for index in items.indices {
            let item = items[index]
            let blueprintID = item.int("blueprint_type_id") ?? 0
            var price: Double?
            var source: String?
            var notForSale: String?
            if item.bool("owned") {
                notForSale = "You own it"
            } else if !marketable.contains(blueprintID) {
                notForSale = item.string("tech") == "T2" ? "Invention only" : "Not sold on the market"
            } else if let sell = books[blueprintID]?.double("sell") {
                price = sell
                source = "\(buyHub) sell orders"
            } else if let base = basePrice[blueprintID] {
                price = base
                source = "CCP base price – no sell orders at \(buyHub)"
            } else {
                notForSale = "No sell orders at \(buyHub)"
            }

            let gain = item.double("gain")
            var runs: Int?
            var seconds: Double?
            var marketDays: Double?
            if let price, let gain, gain > 0 {
                let needed = Int((price / gain).rounded(.up))
                runs = needed
                seconds = Double(needed) * (item.double("build_seconds") ?? 0)
                let units = Double(needed * (item.int("units_per_run") ?? 1))
                if let perDay = item.double("sold_per_day"), perDay > 0 { marketDays = units / perDay }
            } else if let price, let gain, gain < 0 {
                // Never pays back. Shown as a negative number: −21 = every 21 runs you'd be
                // another blueprint's price worse off than just selling the materials.
                runs = -Int((price / -gain).rounded(.up))
            }

            // Break-even sale price: what each unit would have to sell for so a run stops losing
            // against selling the materials. gain = price × units × (1 − fees) − job fee − materials.
            if let gain, gain < 0, let used = item.dict("sale_check")?.double("used") ?? item.double("sell_price") {
                let units = Double(max(item.int("units_per_run") ?? 1, 1))
                let keep = 1 - (item.double("sale_fee_rate") ?? 0)
                if keep > 0 {
                    let breakEven = used + (-gain) / (units * keep)
                    items[index]["break_even_price"] = breakEven
                    items[index]["price_gap"] = breakEven - used
                    items[index]["current_price"] = used
                }
            }
            items[index]["blueprint_price"] = price as Any
            items[index]["blueprint_price_source"] = source as Any
            items[index]["not_for_sale"] = notForSale as Any
            items[index]["payback_runs"] = runs as Any
            items[index]["payback_seconds"] = seconds as Any
            items[index]["payback_market_days"] = marketDays as Any
            items[index]["blueprint_check"] = blueprintChecks[blueprintID] as Any
        }

        result["items"] = items
        result["buy_hub"] = buyHub
        result["assume_me"] = assumeME
        result["lookback_days"] = fairSettings.lookbackDays
        result["price_gaps"] = (result.int("price_gaps") ?? 0) + blueprintGaps
        return result
    }
}
