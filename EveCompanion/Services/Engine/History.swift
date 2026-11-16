import Foundation

/// The one time range every page uses (Settings in the sidebar). 0 = everything stored.
enum HistoryRange {
    static let key = "history.rangeDays"
    static let defaultDays = 365
    static let choices: [(days: Int, label: String)] = [(30, "30 Days"), (90, "90 Days"), (365, "1 Year"), (0, "All")]

    static var days: Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? defaultDays
    }

    static func label(_ days: Int) -> String {
        choices.first { $0.days == days }?.label ?? "\(days) Days"
    }

    /// Start of the range as an ISO string ("2025-11-13T23:00:00Z"), nil for All.
    static func since(_ days: Int = HistoryRange.days, now: Date = Date()) -> Date? {
        days > 0 ? now.addingTimeInterval(-Double(days) * 86400) : nil
    }
}

/// Local history (Data/history.sqlite): everything ESI only keeps for a while – wallet journal,
/// transactions, mining ledger, orders, industry jobs – plus daily net worth, hub order-book
/// snapshots for tracked items, and your order checks. Collected whenever the app refreshes.
/// Every personal row carries character_id so alts can be added later.
actor HistoryStore {
    static let shared = HistoryStore()
    static let path = SDE.dataDir.appending(path: "history.sqlite")

    static let schema = """
    CREATE TABLE IF NOT EXISTS journal (
        character_id INTEGER, id INTEGER, date TEXT, ref_type TEXT, amount REAL, balance REAL,
        context_id INTEGER, context_id_type TEXT, description TEXT,
        PRIMARY KEY (character_id, id));
    CREATE INDEX IF NOT EXISTS journal_date ON journal(character_id, date);
    CREATE TABLE IF NOT EXISTS transactions (
        character_id INTEGER, transaction_id INTEGER, date TEXT, type_id INTEGER, quantity INTEGER,
        unit_price REAL, is_buy INTEGER, location_id INTEGER, journal_ref_id INTEGER,
        PRIMARY KEY (character_id, transaction_id));
    CREATE INDEX IF NOT EXISTS transactions_date ON transactions(character_id, date);
    CREATE TABLE IF NOT EXISTS mining (
        character_id INTEGER, date TEXT, type_id INTEGER, solar_system_id INTEGER, quantity INTEGER,
        PRIMARY KEY (character_id, date, type_id, solar_system_id));
    CREATE TABLE IF NOT EXISTS orders (
        character_id INTEGER, order_id INTEGER, type_id INTEGER, location_id INTEGER, region_id INTEGER,
        is_buy INTEGER, price REAL, volume_total INTEGER, volume_remain INTEGER, issued TEXT,
        duration INTEGER, escrow REAL, state TEXT, updated TEXT,
        PRIMARY KEY (character_id, order_id));
    CREATE TABLE IF NOT EXISTS order_checks (
        character_id INTEGER, order_id INTEGER, time REAL, price REAL, best_other REAL,
        beaten INTEGER, competing_units INTEGER);
    CREATE INDEX IF NOT EXISTS order_checks_time ON order_checks(character_id, time);
    CREATE TABLE IF NOT EXISTS jobs (
        character_id INTEGER, job_id INTEGER, activity_id INTEGER, blueprint_id INTEGER,
        blueprint_type_id INTEGER, product_type_id INTEGER, runs INTEGER, me INTEGER, cost REAL,
        facility_id INTEGER, start_date TEXT, end_date TEXT, completed_date TEXT, status TEXT,
        successful_runs INTEGER,
        PRIMARY KEY (character_id, job_id));
    CREATE TABLE IF NOT EXISTS daily (
        character_id INTEGER, date TEXT, wallet REAL, assets REAL, sell_orders REAL, escrow REAL, total REAL,
        PRIMARY KEY (character_id, date));
    CREATE TABLE IF NOT EXISTS books (
        hub TEXT, type_id INTEGER, time REAL, sell REAL, buy REAL, sell_volume INTEGER, buy_volume INTEGER,
        sell_orders INTEGER, buy_orders INTEGER, sell_volume_at_best INTEGER, buy_volume_at_best INTEGER);
    CREATE INDEX IF NOT EXISTS books_type ON books(type_id, hub, time);
    CREATE TABLE IF NOT EXISTS watchlist (character_id INTEGER, type_id INTEGER, PRIMARY KEY (character_id, type_id));
    CREATE TABLE IF NOT EXISTS contracts_scanned (contract_id INTEGER PRIMARY KEY, item_count INTEGER, last_seen REAL);
    CREATE TABLE IF NOT EXISTS contract_items (
        contract_id INTEGER, type_id INTEGER, quantity INTEGER, is_included INTEGER,
        is_copy INTEGER, runs INTEGER, me INTEGER, te INTEGER);
    CREATE INDEX IF NOT EXISTS contract_items_contract ON contract_items(contract_id);
    CREATE TABLE IF NOT EXISTS copy_contracts (
        contract_id INTEGER PRIMARY KEY, region_id INTEGER, type_id INTEGER, price REAL, runs INTEGER,
        me INTEGER, te INTEGER, expires REAL, first_seen REAL, last_seen REAL, gone_at REAL, outcome TEXT);
    CREATE INDEX IF NOT EXISTS copy_contracts_region ON copy_contracts(region_id, type_id);
    CREATE TABLE IF NOT EXISTS system_activity (
        hour REAL, system_id INTEGER, ship_kills INTEGER, pod_kills INTEGER, npc_kills INTEGER, jumps INTEGER,
        PRIMARY KEY (hour, system_id));
    CREATE TABLE IF NOT EXISTS killmails (
        killmail_id INTEGER PRIMARY KEY, system_id INTEGER, time REAL, ship_type_id INTEGER, value REAL,
        concord INTEGER, npc INTEGER);
    CREATE INDEX IF NOT EXISTS killmails_system ON killmails(system_id, time);
    CREATE TABLE IF NOT EXISTS station_names (station_id INTEGER PRIMARY KEY, name TEXT, system_id INTEGER);
    CREATE TABLE IF NOT EXISTS structure_places (structure_id INTEGER PRIMARY KEY, name TEXT, system_id INTEGER, type_id INTEGER);
    CREATE TABLE IF NOT EXISTS watch_routes (
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, from_loc INTEGER, to_loc INTEGER, via TEXT, avoid TEXT,
        kind TEXT, created REAL);
    CREATE TABLE IF NOT EXISTS trips (
        id INTEGER PRIMARY KEY AUTOINCREMENT, character_id INTEGER, from_loc INTEGER, to_loc INTEGER,
        started REAL, ended REAL);
    CREATE INDEX IF NOT EXISTS trips_character ON trips(character_id, ended);
    CREATE TABLE IF NOT EXISTS travel_state (
        character_id INTEGER PRIMARY KEY, last_dock INTEGER, undocked INTEGER, undocked_at REAL);
    """

    private var db: SQLiteDB?
    private var tracked: Set<Int> = []
    private var lastSync: [Int: Date] = [:]
    private var running: Task<Void, Never>?
    private(set) var lastErrors: [String] = []

    // MARK: - Database

    private func open() throws -> SQLiteDB {
        if let db { return db }
        try FileManager.default.createDirectory(at: SDE.dataDir, withIntermediateDirectories: true)
        let database = try SQLiteDB(path: Self.path.path(percentEncoded: false), readOnly: false)
        try database.execute(Self.schema)
        // Added 15 Nov 2026 (gank matching): who attacked, and who died.
        try? database.execute("ALTER TABLE killmails ADD COLUMN attackers TEXT")
        try? database.execute("ALTER TABLE killmails ADD COLUMN victim_character INTEGER")
        db = database
        return database
    }

    // MARK: - Public contract items (Contracts.swift)
    // A contract's items never change, so they're read from ESI once and kept here.

    /// Which of these contracts have already been read.
    func scannedContracts(_ ids: [Int]) -> Set<Int> {
        guard !ids.isEmpty, let rows = try? open().query("SELECT contract_id FROM contracts_scanned") else { return [] }
        let wanted = Set(ids)
        return Set(rows.compactMap { $0.int("contract_id") }).intersection(wanted)
    }

    /// Store one contract's items (an empty list = nothing usable, e.g. it had already gone).
    func saveContractItems(_ contractID: Int, _ items: [JSONDict]) {
        try? transaction { db in
            try db.run("DELETE FROM contract_items WHERE contract_id = ?", [contractID])
            for item in items {
                let included: Int = item.bool("is_included") ? 1 : 0
                let copy: Int = item.bool("is_blueprint_copy") ? 1 : 0
                try db.run("INSERT INTO contract_items VALUES (?,?,?,?,?,?,?,?)", [
                    contractID, item.int("type_id"), item.int("quantity") ?? 1, included, copy,
                    item.int("runs"), item.int("material_efficiency"), item.int("time_efficiency"),
                ])
            }
            try db.run("INSERT OR REPLACE INTO contracts_scanned VALUES (?,?,?)",
                       [contractID, items.count, Date().timeIntervalSince1970])
        }
    }

    /// Mark contracts as still listed, and forget ones not seen for a week (they've ended).
    func touchContracts(_ ids: [Int]) {
        let now = Date().timeIntervalSince1970
        try? transaction { db in
            let update = try db.prepare("UPDATE contracts_scanned SET last_seen = ? WHERE contract_id = ?")
            for id in ids { try update.run([now, id]) }
            let cutoff = now - 7 * 86400
            try db.run("DELETE FROM contract_items WHERE contract_id IN (SELECT contract_id FROM contracts_scanned WHERE last_seen < ?)", [cutoff])
            try db.run("DELETE FROM contracts_scanned WHERE last_seen < ?", [cutoff])
        }
    }

    // MARK: - Copy contract tracking (what probably sold)
    // ESI only lists open contracts. A copy contract that vanishes before its expiry date was
    // probably bought (or the seller cancelled it – there's no telling the two apart).

    /// Record this scan: new and still-open copy contracts, and which have gone since last time.
    func trackCopyContracts(regionID: Int, offers: [JSONDict], openIDs: Set<Int>) {
        let now = Date().timeIntervalSince1970
        try? transaction { db in
            let upsert = try db.prepare("""
                INSERT INTO copy_contracts VALUES (?,?,?,?,?,?,?,?,?,?,NULL,NULL)
                ON CONFLICT(contract_id) DO UPDATE SET last_seen = excluded.last_seen
                """)
            for offer in offers {
                let expires: Double? = ISODate.parse(offer.string("expires"))?.timeIntervalSince1970
                try upsert.run([offer.int("contract_id"), regionID, offer.int("type_id"), offer.double("price"),
                                offer.int("runs"), offer.int("me"), offer.int("te"), expires, now, now])
            }
            let open = try db.query("SELECT contract_id, expires FROM copy_contracts WHERE region_id = ? AND gone_at IS NULL",
                                    [regionID])
            let mark = try db.prepare("UPDATE copy_contracts SET gone_at = ?, outcome = ? WHERE contract_id = ?")
            for row in open {
                guard let id = row.int("contract_id"), !openIDs.contains(id) else { continue }
                let expires = row.double("expires") ?? 0
                try mark.run([now, expires > now ? "probably_sold" : "expired", id])
            }
            // Kept for good, like the rest of the history – so any History range (1 year, All) works.
        }
    }

    /// {type_id: {sold, median_per_run}} for copies that probably sold in the last `days` days
    /// (0 = all of it), plus when tracking started in this region.
    func copySales(regionID: Int, days: Int) -> (sales: [Int: JSONDict], since: Double?) {
        let cutoff = days > 0 ? Date().timeIntervalSince1970 - Double(days) * 86400 : 0
        let rows = (try? open().query("""
            SELECT type_id, price, runs FROM copy_contracts
            WHERE region_id = ? AND outcome = 'probably_sold' AND gone_at >= ?
            """, [regionID, cutoff])) ?? []
        var perRun: [Int: [Double]] = [:]
        for row in rows {
            guard let type = row.int("type_id"), let price = row.double("price"),
                  let runs = row.int("runs"), runs > 0 else { continue }
            perRun[type, default: []].append(price / Double(runs))
        }
        var sales: [Int: JSONDict] = [:]
        for (type, prices) in perRun {
            sales[type] = ["sold": prices.count, "median_per_run": Market.median(prices) as Any]
        }
        let since = (try? open().query("SELECT MIN(first_seen) AS since FROM copy_contracts WHERE region_id = ?",
                                       [regionID]).first?.double("since")) ?? nil
        return (sales, since)
    }

    /// {contract_id: [items]} for the given contracts.
    func contractItems(_ ids: [Int]) -> [Int: [JSONDict]] {
        guard !ids.isEmpty, let rows = try? open().query("SELECT * FROM contract_items") else { return [:] }
        let wanted = Set(ids)
        var result: [Int: [JSONDict]] = [:]
        for row in rows {
            guard let id = row.int("contract_id"), wanted.contains(id) else { continue }
            result[id, default: []].append(row)
        }
        return result
    }

    // MARK: - System activity (Haul › Route, Watch List)
    // CCP's hourly kills / jumps per system, kept 30 days so 24 h and 7 d totals build up.

    /// Store one hour of CCP's figures: [system_id: (ship, pod, npc kills, jumps)].
    func saveSystemActivity(hour: Double, _ rows: [Int: (ship: Int, pod: Int, npc: Int, jumps: Int)]) {
        try? transaction { db in
            let insert = try db.prepare("INSERT OR REPLACE INTO system_activity VALUES (?,?,?,?,?,?)")
            for (system, r) in rows { try insert.run([hour, system, r.ship, r.pod, r.npc, r.jumps]) }
            try db.run("DELETE FROM system_activity WHERE hour < ?", [hour - 30 * 86400])
        }
    }

    /// Totals since `since` for these systems: {system_id: {ship_kills, pod_kills, jumps, hours}}, and the
    /// earliest hour stored (how far back the app has been watching).
    func systemActivity(_ systems: [Int], since: Double) -> (rows: [Int: JSONDict], firstHour: Double?) {
        guard !systems.isEmpty, let db = try? open() else { return ([:], nil) }
        let list = systems.map(String.init).joined(separator: ",")
        var result: [Int: JSONDict] = [:]
        for r in (try? db.query("""
            SELECT system_id, SUM(ship_kills) AS ship_kills, SUM(pod_kills) AS pod_kills, SUM(jumps) AS jumps,
                   COUNT(*) AS hours FROM system_activity
            WHERE hour >= ? AND system_id IN (\(list)) GROUP BY system_id
            """, [since])) ?? [] {
            if let id = r.int("system_id") { result[id] = r }
        }
        let first = (try? db.query("SELECT MIN(hour) AS first FROM system_activity"))?.first?.double("first")
        return (result, first)
    }

    /// Killmails already read (they never change).
    func knownKillmails(_ ids: [Int]) -> [Int: JSONDict] {
        guard !ids.isEmpty, let db = try? open() else { return [:] }
        var result: [Int: JSONDict] = [:]
        for chunk in ids.chunked(500) {
            for r in (try? db.query("SELECT * FROM killmails WHERE killmail_id IN (\(chunk.map(String.init).joined(separator: ",")))")) ?? [] {
                if let id = r.int("killmail_id") { result[id] = r }
            }
        }
        return result
    }

    func saveKillmail(_ k: JSONDict) {
        try? open().run("""
            INSERT OR REPLACE INTO killmails
            (killmail_id, system_id, time, ship_type_id, value, concord, npc, attackers, victim_character)
            VALUES (?,?,?,?,?,?,?,?,?)
            """, [
            k.int("killmail_id"), k.int("system_id"), k.double("time"), k.int("ship_type_id"),
            k.double("value"), k.int("concord") ?? 0, k.int("npc") ?? 0, k.string("attackers") ?? "",
            k.int("victim_character"),
        ])
        try? open().run("DELETE FROM killmails WHERE time < ?", [Date().timeIntervalSince1970 - 30 * 86400])
    }

    // MARK: - Station names (Haul › Route search) – fetched from EVE once, kept.

    func stationNameIDs() -> Set<Int> {
        Set(((try? open().query("SELECT station_id FROM station_names")) ?? []).compactMap { $0.int("station_id") })
    }

    func saveStationNames(_ rows: [(id: Int, name: String, system: Int)]) {
        try? transaction { db in
            let insert = try db.prepare("INSERT OR REPLACE INTO station_names VALUES (?,?,?)")
            for r in rows { try insert.run([r.id, r.name, r.system]) }
        }
    }

    /// Every NPC station in these systems, by name.
    func stationsIn(_ systems: [Int]) -> [JSONDict] {
        guard !systems.isEmpty, let db = try? open() else { return [] }
        return (try? db.query("SELECT station_id, name, system_id FROM station_names WHERE system_id IN (\(systems.map(String.init).joined(separator: ","))) ORDER BY name")) ?? []
    }

    // MARK: - Watch List: your routes, trips you've flown (Watch.swift)

    func watchRoutes() -> [JSONDict] {
        (try? open().query("SELECT * FROM watch_routes ORDER BY created")) ?? []
    }

    /// Saving a route that's already watched (same start, end and stops) updates it instead of adding a second.
    func addWatchRoute(name: String, from: Int, to: Int, via: String, avoid: String, kind: String) {
        let viaIDs = via.split(separator: ",").compactMap { $0.split(separator: "|").first }.joined(separator: ",")
        let existing = ((try? open().query("SELECT id, via, kind FROM watch_routes WHERE from_loc = ? AND to_loc = ?", [from, to])) ?? [])
            .first { row in
                (row.string("via") ?? "").split(separator: ",").compactMap { $0.split(separator: "|").first }.joined(separator: ",") == viaIDs
            }
        if let id = existing?.int("id") {
            // Keep "mine" over "pinned" – something you saved yourself stays yours.
            let newKind = existing?.string("kind") == "mine" ? "mine" : kind
            try? open().run("UPDATE watch_routes SET name = ?, avoid = ?, kind = ? WHERE id = ?", [name, avoid, newKind, id])
        } else {
            try? open().run("INSERT INTO watch_routes (name, from_loc, to_loc, via, avoid, kind, created) VALUES (?,?,?,?,?,?,?)",
                            [name, from, to, via, avoid, kind, Date().timeIntervalSince1970])
        }
    }

    func deleteWatchRoute(_ id: Int) {
        try? open().run("DELETE FROM watch_routes WHERE id = ?", [id])
    }

    func renameWatchRoute(_ id: Int, name: String) {
        try? open().run("UPDATE watch_routes SET name = ? WHERE id = ?", [name, id])
    }

    func travelState(_ character: Int) -> JSONDict? {
        (try? open().query("SELECT * FROM travel_state WHERE character_id = ?", [character]))?.first
    }

    func setTravelState(_ character: Int, lastDock: Int?, undocked: Bool, at: Double?) {
        try? open().run("INSERT OR REPLACE INTO travel_state VALUES (?,?,?,?)", [character, lastDock, undocked ? 1 : 0, at])
    }

    func addTrip(_ character: Int, from: Int, to: Int, started: Double?, ended: Double) {
        try? open().run("INSERT INTO trips (character_id, from_loc, to_loc, started, ended) VALUES (?,?,?,?,?)",
                        [character, from, to, started, ended])
    }

    /// Trips since `since`, both directions together: {a, b (a < b), trips, forward (a→b count), last}.
    func tripPairs(_ character: Int, since: Double) -> [JSONDict] {
        (try? open().query("""
            SELECT MIN(from_loc, to_loc) AS a, MAX(from_loc, to_loc) AS b, COUNT(*) AS trips,
                   SUM(CASE WHEN from_loc < to_loc THEN 1 ELSE 0 END) AS forward, MAX(ended) AS last
            FROM trips WHERE character_id = ? AND ended >= ? GROUP BY a, b ORDER BY trips DESC
            """, [character, since])) ?? []
    }

    func tripCount(_ character: Int) -> Int {
        (try? open().query("SELECT COUNT(*) AS n FROM trips WHERE character_id = ?", [character]))?.first?.int("n") ?? 0
    }

    /// How often you've docked at each place since `since` (both ends of every trip).
    func dockVisits(_ character: Int, since: Double) -> [Int: Int] {
        var visits: [Int: Int] = [:]
        for r in (try? open().query("SELECT from_loc, to_loc FROM trips WHERE character_id = ? AND ended >= ?", [character, since])) ?? [] {
            if let a = r.int("from_loc") { visits[a, default: 0] += 1 }
            if let b = r.int("to_loc") { visits[b, default: 0] += 1 }
        }
        return visits
    }

    /// Days you've mined in each system since `since`.
    func miningDays(_ character: Int, since: String) -> [Int: Int] {
        var days: [Int: Int] = [:]
        for r in (try? open().query("SELECT solar_system_id, COUNT(DISTINCT date) AS n FROM mining WHERE character_id = ? AND date >= ? GROUP BY solar_system_id", [character, since])) ?? [] {
            if let system = r.int("solar_system_id") { days[system] = r.int("n") ?? 0 }
        }
        return days
    }

    /// Systems you've mined in since `since` (date text yyyy-MM-dd).
    func minedSystems(_ character: Int, since: String) -> [Int] {
        ((try? open().query("SELECT DISTINCT solar_system_id FROM mining WHERE character_id = ? AND date >= ?", [character, since])) ?? [])
            .compactMap { $0.int("solar_system_id") }
    }

    /// Facilities of industry jobs that ended after `since` (or are still running).
    func jobFacilities(_ character: Int, since: String) -> [Int] {
        ((try? open().query("SELECT DISTINCT facility_id FROM jobs WHERE character_id = ? AND end_date >= ?", [character, since])) ?? [])
            .compactMap { $0.int("facility_id") }
    }

    /// Where your market orders with something left on them sit.
    func orderLocations(_ character: Int, since: String) -> [Int] {
        ((try? open().query("SELECT DISTINCT location_id FROM orders WHERE character_id = ? AND volume_remain > 0 AND issued >= ?", [character, since])) ?? [])
            .compactMap { $0.int("location_id") }
    }

    /// Player structures the app has learned about (where you were docked, or a lookup that worked) – kept,
    /// so a structure EVE won't describe again still has its name and system.
    func structureRow(_ id: Int) -> JSONDict? {
        (try? open().query("SELECT structure_id, name, system_id, type_id FROM structure_places WHERE structure_id = ?", [id]))?.first
    }

    func saveStructure(_ id: Int, name: String?, system: Int, type: Int?) {
        let existing = structureRow(id)
        try? open().run("INSERT OR REPLACE INTO structure_places VALUES (?,?,?,?)", [
            id, name ?? existing?.string("name"), system, type ?? existing?.int("type_id"),
        ])
    }

    func stationRow(_ id: Int) -> JSONDict? {
        (try? open().query("SELECT station_id, name, system_id FROM station_names WHERE station_id = ?", [id]))?.first
    }

    /// Stations whose name holds every word typed, in any order ("duvolle aydo").
    func searchStationNames(_ words: [String], limit: Int = 15) -> [JSONDict] {
        guard !words.isEmpty, let db = try? open() else { return [] }
        let clause = words.map { _ in "name LIKE ?" }.joined(separator: " AND ")
        let params: [Any?] = words.map { "%\($0)%" } + [limit]
        return (try? db.query("SELECT station_id, name, system_id FROM station_names WHERE \(clause) ORDER BY length(name) LIMIT ?", params)) ?? []
    }

    /// Read access for the rest of the engine.
    func query(_ sql: String, _ params: [Any?] = []) throws -> [JSONDict] {
        try open().query(sql, params)
    }

    private func transaction(_ body: (SQLiteDB) throws -> Void) throws {
        let database = try open()
        try database.execute("BEGIN")
        do {
            try body(database)
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Sync (on open / refresh)

    /// Saves anything new from ESI. At most every 5 minutes unless forced; concurrent callers wait.
    func sync(force: Bool = false) async {
        if let running {
            await running.value
            return
        }
        guard let cid = try? await EveAuth.shared.characterID() else { return }
        if !force, let last = lastSync[cid], Date().timeIntervalSince(last) < 300 { return }

        let task = Task { await self.performSync(cid) }
        running = task
        await task.value
        running = nil
        lastSync[cid] = Date()
    }

    private func performSync(_ cid: Int) async {
        var errors: [String] = []
        let now = ISODate.string(Date())

        do {
            let rows = asDicts(try await ESI.getAllPages("characters/\(cid)/wallet/journal/"))
            try transaction { db in
                let insert = try db.prepare("INSERT OR REPLACE INTO journal VALUES (?,?,?,?,?,?,?,?,?)")
                for r in rows {
                    try insert.run([cid, r.int("id"), r.string("date"), r.string("ref_type"), r.double("amount"),
                                    r.double("balance"), r.int("context_id"), r.string("context_id_type"), r.string("description")])
                }
            }
        } catch { errors.append("Journal: \(error.localizedDescription)") }

        do {
            let rows = asDicts(try await ESI.get("characters/\(cid)/wallet/transactions/"))
            try transaction { db in
                let insert = try db.prepare("INSERT OR REPLACE INTO transactions VALUES (?,?,?,?,?,?,?,?,?)")
                for r in rows {
                    try insert.run([cid, r.int("transaction_id"), r.string("date"), r.int("type_id"), r.int("quantity"),
                                    r.double("unit_price"), r.bool("is_buy") ? 1 : 0, r.int("location_id"), r.int("journal_ref_id")])
                }
            }
        } catch { errors.append("Transactions: \(error.localizedDescription)") }

        do {
            let rows = asDicts(try await ESI.getAllPages("characters/\(cid)/mining/"))
            try transaction { db in
                // The day's figure grows during the day – keep the latest.
                let insert = try db.prepare("INSERT OR REPLACE INTO mining VALUES (?,?,?,?,?)")
                for r in rows {
                    try insert.run([cid, r.string("date"), r.int("type_id"), r.int("solar_system_id"), r.int("quantity")])
                }
            }
        } catch { errors.append("Mining: \(error.localizedDescription)") }

        var openOrderTypes = Set<Int>()
        do {
            let openOrders = asDicts(try await ESI.get("characters/\(cid)/orders/"))
            let finished = asDicts((try? await ESI.getAllPages("characters/\(cid)/orders/history/")) ?? [])
            openOrderTypes = Set(openOrders.compactMap { $0.int("type_id") })
            try transaction { db in
                let insert = try db.prepare("INSERT OR REPLACE INTO orders VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
                for (rows, defaultState) in [(finished, "expired"), (openOrders, "open")] {
                    for r in rows {
                        try insert.run([cid, r.int("order_id"), r.int("type_id"), r.int("location_id"), r.int("region_id"),
                                        r.bool("is_buy_order") ? 1 : 0, r.double("price"), r.int("volume_total"),
                                        r.int("volume_remain"), r.string("issued"), r.int("duration"), r.double("escrow"),
                                        r.string("state") ?? defaultState, now])
                    }
                }
            }
        } catch { errors.append("Orders: \(error.localizedDescription)") }

        var ownedBlueprintTypes = Set<Int>()
        do {
            let blueprints = (try? await ESI.characterBlueprints()) ?? []
            ownedBlueprintTypes = Set(blueprints.compactMap { $0.int("type_id") })
            var meByItem: [Int: Int] = [:]
            for bp in blueprints {
                if let item = bp.int("item_id") { meByItem[item] = bp.int("material_efficiency") ?? 0 }
            }
            let rows = asDicts(try await ESI.get("characters/\(cid)/industry/jobs/", params: ["include_completed": "true"]))
            try transaction { db in
                let upsert = try db.prepare("""
                    INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(character_id, job_id) DO UPDATE SET
                        status = excluded.status, end_date = excluded.end_date,
                        completed_date = excluded.completed_date, successful_runs = excluded.successful_runs,
                        cost = excluded.cost, me = COALESCE(jobs.me, excluded.me)
                    """)
                for r in rows {
                    // ME isn't in the job – take it from the blueprint while we still have it.
                    let me = r.int("blueprint_id").flatMap { meByItem[$0] }
                    try upsert.run([cid, r.int("job_id"), r.int("activity_id"), r.int("blueprint_id"),
                                    r.int("blueprint_type_id"), r.int("product_type_id"), r.int("runs"), me,
                                    r.double("cost"), r.int("facility_id"), r.string("start_date"), r.string("end_date"),
                                    r.string("completed_date"), r.string("status"), r.int("successful_runs")])
                }
            }
        } catch { errors.append("Industry jobs: \(error.localizedDescription)") }

        do {
            let balance = ((try await ESI.get("characters/\(cid)/wallet/")) as? NSNumber)?.doubleValue ?? 0
            let worth = try await Finances.netWorth(balance)
            try open().run("INSERT OR REPLACE INTO daily VALUES (?,?,?,?,?,?,?)",
                           [cid, ISODate.day(Date()), worth.double("wallet"), worth.double("assets"),
                            worth.double("sell_orders"), worth.double("escrow"), worth.double("total")])
        } catch { errors.append("Net worth: \(error.localizedDescription)") }

        // Items whose order books get snapshotted: what you build, what you trade, what you watch.
        var trackedTypes = openOrderTypes
        if !ownedBlueprintTypes.isEmpty,
           let products = try? SDE.productsForBlueprints(ownedBlueprintTypes) {
            trackedTypes.formUnion(products.compactMap { $0.int("product_type_id") })
        }
        trackedTypes.formUnion(watchlist(cid))
        tracked = trackedTypes

        do { try thin() } catch { errors.append("Tidy-up: \(error.localizedDescription)") }
        lastErrors = errors
    }

    /// Snapshots: full detail 7 days → first per hour to 90 days → first per day to 1 year.
    private func thin() throws {
        let now = Date().timeIntervalSince1970
        let week = now - 7 * 86400, quarter = now - 90 * 86400, year = now - 365 * 86400
        let database = try open()
        try database.run("DELETE FROM books WHERE time < ?", [year])
        try database.run("""
            DELETE FROM books WHERE time < ? AND rowid NOT IN (
                SELECT MIN(rowid) FROM books WHERE time < ? GROUP BY hub, type_id, CAST(time / 86400 AS INTEGER))
            """, [quarter, quarter])
        try database.run("""
            DELETE FROM books WHERE time < ? AND time >= ? AND rowid NOT IN (
                SELECT MIN(rowid) FROM books WHERE time < ? AND time >= ? GROUP BY hub, type_id, CAST(time / 3600 AS INTEGER))
            """, [week, quarter, week, quarter])
        try database.run("DELETE FROM order_checks WHERE time < ?", [year])
        try database.run("""
            DELETE FROM order_checks WHERE time < ? AND rowid NOT IN (
                SELECT MIN(rowid) FROM order_checks WHERE time < ? GROUP BY character_id, order_id, CAST(time / 3600 AS INTEGER))
            """, [week, week])
    }

    // MARK: - Competition snapshots

    /// Called whenever a hub order book is fetched from ESI; stored only for tracked items.
    func recordBook(hub: String, typeID: Int, book: JSONDict) {
        guard tracked.contains(typeID) else { return }
        try? open().run("INSERT INTO books VALUES (?,?,?,?,?,?,?,?,?,?,?)", [
            hub, typeID, Date().timeIntervalSince1970, book.double("sell"), book.double("buy"),
            book.int("sell_volume"), book.int("buy_volume"), book.int("sell_orders"), book.int("buy_orders"),
            book.int("sell_volume_at_best"), book.int("buy_volume_at_best"),
        ])
    }

    /// Sellers / units listed now vs about a week ago (or the oldest snapshot if newer).
    func competitionTrend(hub: String, typeID: Int) -> JSONDict? {
        guard let rows = try? open().query(
            "SELECT time, sell_orders, sell_volume, sell FROM books WHERE type_id = ? AND hub = ? ORDER BY time DESC LIMIT 1",
            [typeID, hub]), let latest = rows.first, let latestTime = latest.double("time") else { return nil }
        let weekAgo = latestTime - 7 * 86400
        let before = (try? open().query(
            "SELECT time, sell_orders, sell_volume, sell FROM books WHERE type_id = ? AND hub = ? AND time <= ? ORDER BY time DESC LIMIT 1",
            [typeID, hub, weekAgo]).first)
            ?? (try? open().query(
                "SELECT time, sell_orders, sell_volume, sell FROM books WHERE type_id = ? AND hub = ? ORDER BY time ASC LIMIT 1",
                [typeID, hub]).first)
        guard let before, let beforeTime = before.double("time"), latestTime - beforeTime >= 3600 else { return nil }
        return [
            "sell_orders_now": latest.int("sell_orders") ?? 0,
            "sell_orders_before": before.int("sell_orders") ?? 0,
            "sell_volume_now": latest.int("sell_volume") ?? 0,
            "sell_volume_before": before.int("sell_volume") ?? 0,
            "lowest_now": latest.double("sell") as Any,
            "lowest_before": before.double("sell") as Any,
            "days": (latestTime - beforeTime) / 86400,
        ]
    }

    /// Your order vs the best competitor, every time Market Orders checks.
    func recordOrderChecks(_ cid: Int, _ rows: [JSONDict]) {
        let now = Date().timeIntervalSince1970
        try? transaction { db in
            let insert = try db.prepare("INSERT INTO order_checks VALUES (?,?,?,?,?,?,?)")
            for r in rows {
                try insert.run([cid, r.int("order_id"), now, r.double("price"), r.double("best_other"),
                                r.bool("beaten") ? 1 : 0, r.int("competing_units")])
            }
        }
    }

    // MARK: - Watchlist

    func watchlist(_ cid: Int) -> [Int] {
        ((try? open().query("SELECT type_id FROM watchlist WHERE character_id = ?", [cid])) ?? [])
            .compactMap { $0.int("type_id") }
    }

    func setWatch(_ cid: Int, typeID: Int, on: Bool) throws {
        if on {
            try open().run("INSERT OR IGNORE INTO watchlist VALUES (?, ?)", [cid, typeID])
            tracked.insert(typeID)
        } else {
            try open().run("DELETE FROM watchlist WHERE character_id = ? AND type_id = ?", [cid, typeID])
        }
    }
}
