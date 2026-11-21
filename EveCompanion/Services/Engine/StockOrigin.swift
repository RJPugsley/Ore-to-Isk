import Foundation

/// Where your free stock came from (19 Nov 2026, user): stock the bought / built pool doesn't
/// cover is split into **mined**, **other source** (loot, salvage, reprocessed loot – anything not
/// bought, mined or built) and **already had** (owned when tracking began).
///
/// EVE doesn't report looting or salvaging, so "other" is the difference: what you own now minus
/// what your history explains (starting stock + bought + built + mined − sold − used in jobs).
/// The first run saves a starting snapshot of everything you own; from then on only what turns up
/// beyond it can be "other". Gifts and transfers between your characters land in "other" too.
enum StockOrigin {
    /// Shares of a type's free stock (add up to 1).
    struct Split {
        let mined: Double
        let other: Double
        let had: Double
    }

    struct Result {
        let split: [Int: Split]
        /// When tracking began (the starting snapshot).
        let since: String
        /// True when this call took the starting snapshot – everything counts as "already had" today.
        let startedNow: Bool
    }

    /// Take the starting snapshot if there isn't one yet (called after each history sync, so
    /// tracking starts the first time the app runs – not only when the Build Planner is opened).
    static func ensureBaseline() async {
        guard let cid = try? await EveAuth.shared.characterID(),
              await HistoryStore.shared.stockBaseline(cid) == nil,
              let owned = try? await Market.ownedQuantities(nil) else { return }
        await HistoryStore.shared.saveStockBaseline(cid, owned, takenAt: ISODate.string(Date()))
    }

    static func freeSplit(types: Set<Int>, boughtStock: [Int: (qty: Double, cost: Double)],
                          settings: Reprocessing.Settings, levels: [Int: Int]) async throws -> Result {
        let cid = try await EveAuth.shared.characterID()
        let store = HistoryStore.shared
        let owned = try await Market.ownedQuantities(nil)   // everything you own, everywhere

        // ---- Starting snapshot ----
        guard let baseline = await store.stockBaseline(cid) else {
            let now = ISODate.string(Date())
            await store.saveStockBaseline(cid, owned, takenAt: now)
            var split: [Int: Split] = [:]
            for type in types { split[type] = Split(mined: 0, other: 0, had: 1) }
            return Result(split: split, since: now, startedNow: true)
        }
        let since = baseline.takenAt
        let sinceDay = String(since.prefix(10))

        // ---- What history explains since the snapshot ----
        var explained: [Int: Double] = [:]
        for (type, qty) in baseline.quantities { explained[type, default: 0] += Double(qty) }
        var mined: [Int: Double] = [:]

        func sums(_ sql: String, _ params: [Any?]) async throws -> [Int: Double] {
            var out: [Int: Double] = [:]
            for row in try await store.query(sql, params) {
                if let type = row.int("type_id") { out[type, default: 0] += row.double("qty") ?? 0 }
            }
            return out
        }
        let bought = try await sums("""
            SELECT type_id, SUM(quantity) AS qty FROM transactions
            WHERE character_id = ? AND is_buy = 1 AND date >= ? GROUP BY type_id
            """, [cid, since])
        let sold = try await sums("""
            SELECT type_id, SUM(quantity) AS qty FROM transactions
            WHERE character_id = ? AND is_buy = 0 AND date >= ? GROUP BY type_id
            """, [cid, since])
        // Mining days are whole days – the snapshot's own day counts (better to under-count loot).
        let minedOre = try await sums("""
            SELECT type_id, SUM(quantity) AS qty FROM mining
            WHERE character_id = ? AND date >= ? GROUP BY type_id
            """, [cid, sinceDay])

        // Ore refines out of sight: ore you mined, bought or started with also explains its minerals.
        let oreIDs = Array(Set(minedOre.keys).union(bought.keys).union(baseline.quantities.keys))
        let shares = (try? await Mining.oreAsMinerals(oreIDs, settings: settings, levels: levels)) ?? [:]
        func addOre(_ ore: Int, _ qty: Double, minedToo: Bool) {
            guard let parts = shares[ore] else { return }
            for part in parts {
                explained[part.mineral, default: 0] += qty * part.perUnit
                if minedToo { mined[part.mineral, default: 0] += qty * part.perUnit }
            }
        }
        for (type, qty) in bought { explained[type, default: 0] += qty; addOre(type, qty, minedToo: false) }
        for (type, qty) in sold { explained[type, default: 0] -= qty }
        for (type, qty) in minedOre {
            explained[type, default: 0] += qty
            mined[type, default: 0] += qty
            addOre(type, qty, minedToo: true)
        }
        for (type, qty) in baseline.quantities { addOre(type, Double(qty), minedToo: false) }

        // Jobs: started ones used materials, finished ones added products.
        let jobs = try await store.query("""
            SELECT blueprint_type_id, product_type_id, runs, successful_runs, me, start_date, end_date
            FROM jobs WHERE character_id = ? AND activity_id = 1 AND status != 'cancelled'
            AND (start_date >= ? OR end_date >= ?)
            """, [cid, since, since])
        let nowText = ISODate.string(Date())
        for job in jobs {
            guard let bpType = job.int("blueprint_type_id"), let data = try? SDE.manufacturing(bpType) else { continue }
            let runs = job.int("runs") ?? 1
            if let start = job.string("start_date"), start >= since {
                let mod = 1 - Double(job.int("me") ?? 0) / 100
                for m in data.dicts("materials") {
                    let type = m.int("material_type_id") ?? 0
                    let need = max(runs, IndustryCalc.ceilRounded(Double(runs * (m.int("quantity") ?? 0)) * mod))
                    explained[type, default: 0] -= Double(need)
                }
            }
            if let end = job.string("end_date"), end >= since, end <= nowText {
                let product = job.int("product_type_id") ?? data.dict("blueprint")?.int("product_type_id") ?? 0
                let perRun = data.dict("blueprint")?.int("product_quantity") ?? 1
                explained[product, default: 0] += Double((job.int("successful_runs") ?? runs) * perRun)
            }
        }

        // ---- Split each type's free stock ----
        var split: [Int: Split] = [:]
        for type in types {
            let have = Double(owned[type] ?? 0)
            let free = max(0, have - max(0, boughtStock[type]?.qty ?? 0))
            guard free > 0 else { split[type] = Split(mined: 0, other: 0, had: 1); continue }
            let other = min(free, max(0, have - max(0, explained[type] ?? 0)))
            let rest = free - other
            let minedPart = min(rest, max(0, mined[type] ?? 0))
            let had = rest - minedPart
            split[type] = Split(mined: minedPart / free, other: other / free, had: had / free)
        }
        return Result(split: split, since: since, startedNow: false)
    }
}
