import Foundation

/// Sanity checks for market prices, so a thin, baited or manipulated market can't
/// make something look far more (or less) profitable than it really is.
///
///   live price  = average price of the best orders covering the units you'd trade
///                 (one-unit bait orders barely count; buy orders whose minimum
///                 quantity is above your amount are skipped)
///   fair price  = median of the region's daily average price over the lookback
///                 (the last 7 days' median instead when the market has clearly moved)
///   used price  = live, unless live is more than `band` above fair ("inflated") –
///                 then fair. Below fair by more than `band` is flagged "dumped" but
///                 live is kept, because that's what you'd actually get.
enum FairPrice {
    struct Settings {
        var band: Double = 0.5            // ±50%
        var lookbackDays: Int = 30
        var trendThreshold: Double = 0.15 // 7-day median this far from the lookback median = trending
        var batchRuns: Int = 10

        /// The app-wide choices from the Price Checks menu (UserDefaults keys `priceCheck.*`).
        static var current: Settings {
            let defaults = UserDefaults.standard
            var settings = Settings()
            let band = defaults.integer(forKey: "priceCheck.band")
            let lookback = defaults.integer(forKey: "priceCheck.lookbackDays")
            let runs = defaults.integer(forKey: "priceCheck.batchRuns")
            if band > 0 { settings.band = Double(band) / 100 }
            if lookback > 0 { settings.lookbackDays = lookback }
            if runs > 0 { settings.batchRuns = runs }
            return settings
        }
    }

    // MARK: Depth

    /// Average price of the cheapest sell orders covering `quantity` units.
    static func sellDepthPrice(_ book: JSONDict, quantity: Int) -> Double? {
        walk(book.dicts("sell_ladder"), quantity: quantity, allowed: { _ in true })
    }

    /// Average price of the best buy orders covering `quantity` units, skipping orders
    /// that only buy in bigger lots than you have (the minimum-quantity trap).
    static func buyDepthPrice(_ book: JSONDict, quantity: Int) -> Double? {
        walk(book.dicts("buy_ladder"), quantity: quantity, allowed: { ($0.int("min") ?? 1) <= max(quantity, 1) })
    }

    private static func walk(_ ladder: [JSONDict], quantity: Int, allowed: (JSONDict) -> Bool) -> Double? {
        var left = max(quantity, 1)
        var units = 0
        var value = 0.0
        for order in ladder where allowed(order) {
            guard let price = order.double("price") ?? order.double("p") else { continue }
            let available = order.int("v") ?? 0
            guard available > 0 else { continue }
            let take = min(available, left)
            units += take
            value += Double(take) * price
            left -= take
            if left == 0 { break }
        }
        return units > 0 ? value / Double(units) : nil
    }

    // MARK: Check

    /// Compare a live price with the region's history.
    /// Returns {live, fair, used, status, trend, ratio, thin, speed, speed_reason, days_to_sell,
    /// sold_per_day, sold_per_day_7}.
    /// speed: "quick" = the last 7 days sold at least 25% more per day than the lookback average;
    ///        "slow"  = the last 7 days sold at least 25% less per day than the lookback average.
    /// status: ok · inflated · dumped · no_history · no_orders
    static func check(live: Double?, history: JSONDict?, quantity: Int, settings: Settings) -> JSONDict {
        let lookbackMedian = history?.double("median_price")
        let weekMedian = history?.double("median_7")
        let soldPerDay = history?.double("sold_per_day") ?? 0
        let soldPerDay7 = history?.double("sold_per_day_7") ?? 0

        var fair: Double? = lookbackMedian
        var trend: String?
        if let lookbackMedian, let weekMedian, lookbackMedian > 0, soldPerDay7 >= 1 {
            let move = weekMedian / lookbackMedian - 1
            if abs(move) >= settings.trendThreshold {
                trend = move > 0 ? "up" : "down"
                fair = weekMedian   // the market has really moved – follow it
            }
        }

        let status: String
        var used: Double? = live
        var ratio: Double?
        if live == nil {
            status = "no_orders"
        } else if let live, let fair, fair > 0 {
            let r = live / fair
            ratio = r
            if r > 1 + settings.band {
                status = "inflated"
                used = fair
            } else if r < 1 - settings.band {
                status = "dumped"
            } else {
                status = "ok"
            }
        } else {
            status = "no_history"
        }

        let daysToSell: Double? = soldPerDay > 0 ? Double(max(quantity, 1)) / soldPerDay : nil
        let thin: Bool = history != nil && (soldPerDay < 1 || Double(quantity) > soldPerDay)
        var speed: String?
        var speedReason: String?
        if history != nil, soldPerDay > 0 {
            let pace = soldPerDay7 / soldPerDay
            if pace >= 1.25 {
                speed = "quick"
                speedReason = "recent"
            } else if pace <= 0.75 {
                speed = "slow"
                speedReason = "recent"
            }
        }
        return [
            "live": live as Any,
            "fair": fair as Any,
            "used": used as Any,
            "status": status,
            "trend": trend as Any,
            "ratio": ratio as Any,
            "thin": thin,
            "speed": speed as Any,
            "speed_reason": speedReason as Any,
            "sold_per_day_7": soldPerDay7,
            "median_7": weekMedian as Any,
            "median_lookback": lookbackMedian as Any,
            "days_to_sell": daysToSell as Any,
            "sold_per_day": soldPerDay,
        ]
    }

    /// Gap between the best buy and best sell: "wide" when sell is more than double buy
    /// (the price is shaky), "tight" when they're within 10% (a healthy, liquid market), else nil.
    static func spread(_ book: JSONDict) -> String? {
        guard let sell = book.double("sell"), let buy = book.double("buy"), sell > 0, buy > 0 else { return nil }
        let gap = (sell - buy) / sell
        if gap > 0.5 { return "wide" }
        if gap <= 0.1 { return "tight" }
        return nil
    }
}
