import Foundation

/// Originally `sde.py`: CCP's static data (JSON Lines zip) → Data/sde.sqlite,
/// plus the queries the rest of the engine uses.
enum SDE {
    static let dataDir = EngineSettings.appFolder.appending(path: "Data")
    static let dbPath = dataDir.appending(path: "sde.sqlite")
    static let zipPath = dataDir.appending(path: "sde-latest-jsonl.zip")

    static let latestURL = URL(string: "https://developers.eveonline.com/static-data/eve-online-static-data-latest-jsonl.zip")!
    static let latestBuildURL = URL(string: "https://developers.eveonline.com/static-data/tranquility/latest.jsonl")!

    static let neededFiles = [
        "_sde.jsonl", "categories.jsonl", "groups.jsonl", "types.jsonl", "blueprints.jsonl",
        "typeMaterials.jsonl", "typeDogma.jsonl", "mapSolarSystems.jsonl", "mapRegions.jsonl",
        "marketGroups.jsonl", "npcStations.jsonl", "typeBonus.jsonl",
    ]

    static let schema = """
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE categories (category_id INTEGER PRIMARY KEY, name TEXT);
    CREATE TABLE groups (group_id INTEGER PRIMARY KEY, category_id INTEGER, name TEXT);
    CREATE TABLE types (
        type_id INTEGER PRIMARY KEY, name TEXT, group_id INTEGER, category_id INTEGER,
        market_group_id INTEGER, meta_group_id INTEGER, published INTEGER,
        volume REAL, packaged_volume REAL, portion_size INTEGER, base_price REAL
    );
    CREATE INDEX types_name ON types(name COLLATE NOCASE);
    CREATE TABLE bp_manufacturing (
        blueprint_type_id INTEGER PRIMARY KEY, product_type_id INTEGER, product_quantity INTEGER,
        time INTEGER, max_runs INTEGER, copy_time INTEGER
    );
    CREATE INDEX bp_product ON bp_manufacturing(product_type_id);
    CREATE TABLE bp_materials (blueprint_type_id INTEGER, material_type_id INTEGER, quantity INTEGER);
    CREATE TABLE reaction_products (product_type_id INTEGER PRIMARY KEY, formula_type_id INTEGER);
    CREATE TABLE market_groups (
        market_group_id INTEGER PRIMARY KEY, parent_group_id INTEGER, name TEXT, has_types INTEGER, icon_id INTEGER);
    CREATE INDEX types_market_group ON types(market_group_id);
    CREATE INDEX bp_materials_bp ON bp_materials(blueprint_type_id);
    CREATE TABLE bp_skills (blueprint_type_id INTEGER, skill_type_id INTEGER, level INTEGER);
    CREATE TABLE type_materials (type_id INTEGER, material_type_id INTEGER, quantity INTEGER);
    CREATE INDEX type_materials_type ON type_materials(type_id);
    CREATE TABLE type_reprocess_skill (type_id INTEGER PRIMARY KEY, skill_type_id INTEGER);
    CREATE TABLE solar_systems (
        system_id INTEGER PRIMARY KEY, name TEXT, security REAL, region_id INTEGER, region_name TEXT
    );
    CREATE INDEX systems_name ON solar_systems(name COLLATE NOCASE);
    CREATE TABLE ship_cargo (
        type_id INTEGER PRIMARY KEY, capacity REAL, bonus_skill_id INTEGER, bonus_per_level REAL);
    CREATE TABLE cargo_modifiers (type_id INTEGER PRIMARY KEY, multiplier REAL);
    CREATE TABLE npc_stations (station_id INTEGER PRIMARY KEY, system_id INTEGER, type_id INTEGER);
    """

    /// Bump when the tables change; an older local database is then rebuilt automatically.
    static let schemaVersion = "8"   // 3: copy_time · 4: reaction_products · 5: market_groups · 6: ship_cargo, cargo_modifiers · 7: npc_stations · 8: hull cargo bonus from typeBonus.jsonl (15 Nov 2026)
    /// Dogma attribute "reprocessingSkillType".
    static let attrReprocessingSkill = 790
    /// Dogma attributes that change a ship's cargo hold: expanders (multiplier, e.g. 1.275)
    /// and cargohold optimization rigs (percent bonus, e.g. 15).
    static let attrCargoMultiplier = 149
    static let attrCargoBonusPercent = 614
    static let shipCategory = 6
    static let skillCategory = 16

    /// SDE names are localized objects ({"en": ...}); tolerate plain strings too.
    static func en(_ value: Any?) -> String {
        if let dict = value as? JSONDict {
            return (dict["en"] as? String) ?? (dict.values.first as? String) ?? ""
        }
        return (value as? String) ?? ""
    }

    // MARK: - Status

    static func status() async -> JSONDict { await SDEState.shared.status() }

    // MARK: - Build

    /// Download + import if missing or out of date.
    static func update(force: Bool = false) async {
        guard await SDEState.shared.begin() else { return } // already running
        defer { Task { await SDEState.shared.end() } }

        do {
            let current = installedBuild()
            let latest = await latestBuildNumber()
            let schemaOK = installedSchema() == schemaVersion
            if let current, schemaOK, !force, latest == nil || latest == current {
                await SDEState.shared.set(state: "ready", message: "", build: current)
                return
            }
            try await download()
            try await buildDB()
            try? FileManager.default.removeItem(at: zipPath) // keep only the small SQLite
            await SDEState.shared.set(state: "ready", message: "", build: installedBuild())
        } catch {
            if let build = installedBuild() {
                await SDEState.shared.set(state: "ready", message: "Static data refresh failed: \(error.localizedDescription)", build: build)
            } else {
                await SDEState.shared.set(state: "error", message: "Static data download failed: \(error.localizedDescription)", build: nil)
            }
        }
    }

    static func updateInBackground(force: Bool = false) {
        Task.detached(priority: .utility) { await SDE.update(force: force) }
    }

    /// While an older database exists the calculator keeps working; just show a message.
    private static func progress(_ state: String, _ message: String) async {
        let exists = FileManager.default.fileExists(atPath: dbPath.path(percentEncoded: false))
        await SDEState.shared.set(state: exists ? "ready" : state, message: message, build: nil, keepBuild: true)
    }

    private static func download() async throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        await progress("downloading", "Downloading static data from CCP…")
        var request = URLRequest(url: latestURL)
        request.timeoutInterval = 300
        // Downloaded into memory and written straight into the app's own Data folder,
        // so nothing lands in the system's temporary folders.
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SQLiteError(message: "SDE download failed: HTTP \(http.statusCode)")
        }
        try? FileManager.default.removeItem(at: zipPath)
        try data.write(to: zipPath, options: .atomic)
    }

    /// Extracts the files we need (any folder inside the zip) into a work folder inside Data/
    /// (deleted again once the database is built).
    private static func extract() throws -> URL {
        let folder = dataDir.appending(path: "sde-unzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-j", "-qq", zipPath.path(percentEncoded: false)]
            + neededFiles.flatMap { [$0, "*/\($0)"] }
            + ["-d", folder.path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // 11 = "some patterns didn't match" (each file is listed twice), which is fine.
        guard process.terminationStatus == 0 || process.terminationStatus == 11 else {
            throw SQLiteError(message: "unzip failed (\(process.terminationStatus))")
        }
        return folder
    }

    /// _jsonl – every row of one file.
    /// The hull's cargo hold bonus from its traits: (skill, % per level), or nil.
    /// Traits are {"types": {skillID: [{bonus, bonusText}]}} – the JSONL files may also
    /// write the map as [{"_key": skillID, "_value": [...]}], so both are read.
    static func cargoTrait(_ traits: Any?) -> (skill: Int, perLevel: Double)? {
        // Walk whatever layout CCP uses: {"types": {skill: [bonus]}}, [{"_key": skill, "_value": [bonus]}],
        // {"_key": skill, "bonuses": [...]}, or bonuses carrying their own "skillID".
        var found: (Int, Double)?
        func isCargo(_ bonus: JSONDict) -> Bool {
            let text = en(bonus["bonusText"]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).lowercased()
            return (text.contains("cargo hold capacity") || text.contains("cargohold capacity") || text.contains("cargo capacity"))
                && !text.contains("ore hold") && !text.contains("fleet hangar") && !text.contains("ship maintenance")
        }
        func walk(_ value: Any?, skill: Int?, depth: Int) {
            guard found == nil, depth < 8, let value else { return }
            if let list = value as? [Any] {
                for item in list { walk(item, skill: skill, depth: depth + 1) }
            } else if let dict = value as? JSONDict {
                if dict["bonusText"] != nil {
                    let owner = dict.int("skillID") ?? dict.int("skillTypeID") ?? skill
                    if isCargo(dict), let owner, owner > 0, let bonus = dict.double("bonus"), bonus > 0 { found = (owner, bonus) }
                    return
                }
                // {"_key": skill, "_value": [...]} pairs
                if let key = dict.int("_key"), dict["_value"] != nil {
                    walk(dict["_value"], skill: key, depth: depth + 1)
                    return
                }
                for (key, inner) in dict where key != "roleBonuses" && key != "miscBonuses" && key != "_key" {
                    walk(inner, skill: Int(key) ?? skill, depth: depth + 1)
                }
            }
        }
        walk(traits, skill: nil, depth: 0)
        return found.map { (skill: $0.0, perLevel: $0.1) }
    }

    private static func jsonl(_ folder: URL, _ filename: String) throws -> [JSONDict] {
        let file = folder.appending(path: filename)
        guard let data = try? Data(contentsOf: file) else {
            throw SQLiteError(message: "\(filename) missing from SDE archive")
        }
        var rows: [JSONDict] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let row = try JSONSerialization.jsonObject(with: Data(line)) as? JSONDict {
                rows.append(row)
            }
        }
        return rows
    }

    private static func buildDB() async throws {
        await progress("importing", "Importing static data…")
        let tmpDB = dataDir.appending(path: "sde.building")
        try? FileManager.default.removeItem(at: tmpDB)

        let folder = try extract()
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            let db = try SQLiteDB(path: tmpDB.path(percentEncoded: false), readOnly: false)
            try db.execute(schema)
            try db.execute("BEGIN")
            try db.run("INSERT INTO meta VALUES ('schema', ?)", [schemaVersion])

            for row in try jsonl(folder, "_sde.jsonl") where row.string("_key") == "sde" {
                try db.run("INSERT INTO meta VALUES ('build', ?)", [row.value("buildNumber").map { "\($0)" } ?? "None"])
                try db.run("INSERT INTO meta VALUES ('release_date', ?)", [row.string("releaseDate") ?? ""])
            }

            let insertCategory = try db.prepare("INSERT INTO categories VALUES (?, ?)")
            for r in try jsonl(folder, "categories.jsonl") {
                try insertCategory.run([r.int("_key"), en(r["name"])])
            }

            var groupCategory: [Int: Int] = [:]
            let insertGroup = try db.prepare("INSERT INTO groups VALUES (?, ?, ?)")
            for r in try jsonl(folder, "groups.jsonl") {
                if let key = r.int("_key"), let category = r.int("categoryID") { groupCategory[key] = category }
                try insertGroup.run([r.int("_key"), r.int("categoryID"), en(r["name"])])
            }

            let insertType = try db.prepare("INSERT INTO types VALUES (?,?,?,?,?,?,?,?,?,?,?)")
            let insertShipCargo = try db.prepare("INSERT OR REPLACE INTO ship_cargo VALUES (?,?,?,?)")
            for r in try jsonl(folder, "types.jsonl") {
                // Ships: cargo hold size and the hull's per-level cargo bonus (e.g. Mammoth +5% per Minmatar Hauler level).
                if let group = r.int("groupID"), groupCategory[group] == shipCategory,
                   let capacity = r.double("capacity"), capacity > 0 {
                    let bonus = cargoTrait(r["traits"])
                    try insertShipCargo.run([r.int("_key"), capacity, bonus?.skill, bonus?.perLevel])
                }
                try insertType.run([
                    r.int("_key"), en(r["name"]), r.int("groupID"),
                    r.int("groupID").flatMap { groupCategory[$0] }, r.int("marketGroupID"),
                    r.int("metaGroupID"), r.bool("published") ? 1 : 0,
                    r.double("volume"), r.double("packagedVolume"), r.int("portionSize") ?? 1,
                    r.double("basePrice"),
                ])
            }

            let insertBP = try db.prepare("INSERT OR REPLACE INTO bp_manufacturing VALUES (?,?,?,?,?,?)")
            let insertBPMaterial = try db.prepare("INSERT INTO bp_materials VALUES (?,?,?)")
            let insertBPSkill = try db.prepare("INSERT INTO bp_skills VALUES (?,?,?)")
            let insertReaction = try db.prepare("INSERT OR REPLACE INTO reaction_products VALUES (?,?)")
            for r in try jsonl(folder, "blueprints.jsonl") {
                let bpID = r.int("blueprintTypeID") ?? r.int("_key")
                // Reaction formulas: remember what they make (to tell "reaction" items apart).
                for product in r.dict("activities")?.dict("reaction")?.dicts("products") ?? [] {
                    try insertReaction.run([product.int("typeID"), bpID])
                }
                guard let manufacturing = r.dict("activities")?.dict("manufacturing"),
                      let product = manufacturing.dicts("products").first else { continue }
                let copyTime: Int? = r.dict("activities")?.dict("copying")?.int("time")
                try insertBP.run([bpID, product.int("typeID"), product.int("quantity") ?? 1,
                                  manufacturing.int("time") ?? 0, r.int("maxProductionLimit"), copyTime])
                for m in manufacturing.dicts("materials") {
                    try insertBPMaterial.run([bpID, m.int("typeID"), m.int("quantity")])
                }
                for s in manufacturing.dicts("skills") {
                    try insertBPSkill.run([bpID, s.int("typeID"), s.int("level") ?? 0])
                }
            }

            let insertTypeMaterial = try db.prepare("INSERT INTO type_materials VALUES (?,?,?)")
            for r in try jsonl(folder, "typeMaterials.jsonl") {
                for m in r.dicts("materials") {
                    try insertTypeMaterial.run([r.int("_key"), m.int("materialTypeID"), m.int("quantity")])
                }
            }

            // Which processing skill each ore / ice uses – read from CCP's data.
            let insertSkill = try db.prepare("INSERT OR REPLACE INTO type_reprocess_skill VALUES (?, ?)")
            let insertCargoModifier = try db.prepare("INSERT OR REPLACE INTO cargo_modifiers VALUES (?, ?)")
            for r in try jsonl(folder, "typeDogma.jsonl") {
                for a in r.dicts("dogmaAttributes") where a.int("attributeID") == attrReprocessingSkill {
                    try insertSkill.run([r.int("_key"), a.double("value").map { Int($0) }])
                }
                // Fitted cargo expanders / rigs, as one multiplier each.
                for a in r.dicts("dogmaAttributes") {
                    guard let value = a.double("value") else { continue }
                    if a.int("attributeID") == attrCargoMultiplier, value != 1 {
                        try insertCargoModifier.run([r.int("_key"), value])
                    } else if a.int("attributeID") == attrCargoBonusPercent, value != 0 {
                        try insertCargoModifier.run([r.int("_key"), 1 + value / 100])
                    }
                }
            }

            // Ship bonuses may live in their own file (typeBonus.jsonl) rather than in types.jsonl.
            let setBonus = try db.prepare("UPDATE ship_cargo SET bonus_skill_id = ?, bonus_per_level = ? WHERE type_id = ? AND bonus_skill_id IS NULL")
            for r in (try? jsonl(folder, "typeBonus.jsonl")) ?? [] {
                if let ship = r.int("_key"), let bonus = cargoTrait(r) {
                    try setBonus.run([bonus.skill, bonus.perLevel, ship])
                }
            }

            // Every NPC station and its system (names aren't in the static data – Routes fetches them once).
            let insertStation = try db.prepare("INSERT OR REPLACE INTO npc_stations VALUES (?,?,?)")
            for r in (try? jsonl(folder, "npcStations.jsonl")) ?? [] {
                try insertStation.run([r.int("_key"), r.int("solarSystemID"), r.int("typeID")])
            }

            // The in-game market tree (Ships › Frigates › …). Optional: an archive without it
            // just means an empty Market browser tree.
            let insertMarketGroup = try db.prepare("INSERT OR REPLACE INTO market_groups VALUES (?,?,?,?,?)")
            for r in (try? jsonl(folder, "marketGroups.jsonl")) ?? [] {
                let hasTypes: Int = r.bool("hasTypes") ? 1 : 0
                try insertMarketGroup.run([r.int("_key"), r.int("parentGroupID"), en(r["name"]), hasTypes, r.int("iconID")])
            }

            var regions: [Int: String] = [:]
            for r in try jsonl(folder, "mapRegions.jsonl") {
                if let key = r.int("_key") { regions[key] = en(r["name"]) }
            }
            let insertSystem = try db.prepare("INSERT INTO solar_systems VALUES (?,?,?,?,?)")
            for r in try jsonl(folder, "mapSolarSystems.jsonl") {
                try insertSystem.run([r.int("_key"), en(r["name"]), r.double("securityStatus"),
                                      r.int("regionID"), r.int("regionID").flatMap { regions[$0] } ?? ""])
            }

            try db.execute("COMMIT")
        }

        try? FileManager.default.removeItem(at: dbPath)
        try FileManager.default.moveItem(at: tmpDB, to: dbPath)
    }

    private static func latestBuildNumber() async -> String? {
        var request = URLRequest(url: latestBuildURL)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSONDict,
               row.string("_key") == "sde" {
                return row.value("buildNumber").map { "\($0)" }
            }
        }
        return nil
    }

    private static func metaValue(_ key: String) -> String?? {
        guard FileManager.default.fileExists(atPath: dbPath.path(percentEncoded: false)),
              let db = try? SQLiteDB(path: dbPath.path(percentEncoded: false), readOnly: true),
              let rows = try? db.query("SELECT value FROM meta WHERE key=?", [key]) else { return nil }
        return .some(rows.first?.string("value"))
    }

    static func installedSchema() -> String? {
        guard let value = metaValue("schema") else { return nil }
        return value ?? "1"
    }

    static func installedBuild() -> String? {
        metaValue("build") ?? nil
    }

    // MARK: - Queries

    static func connect() throws -> SQLiteDB {
        guard FileManager.default.fileExists(atPath: dbPath.path(percentEncoded: false)) else {
            throw SQLiteError(message: "Static data is not installed yet – it downloads automatically on first use.")
        }
        return try SQLiteDB(path: dbPath.path(percentEncoded: false), readOnly: true)
    }

    static func typeNames<S: Sequence>(_ typeIDs: S) throws -> [Int: String] where S.Element == Int {
        let ids = Array(Set(typeIDs))
        guard !ids.isEmpty else { return [:] }
        var result: [Int: String] = [:]
        for row in try connect().query("SELECT type_id, name FROM types WHERE type_id IN (\(placeholders(ids.count)))", ids) {
            if let id = row.int("type_id") { result[id] = row.string("name") ?? "" }
        }
        return result
    }

    /// {type_id: {type_id, name, category_id, portion_size, group_name, materials: [{material_type_id, quantity}]}}
    static func typesInfo<S: Sequence>(_ typeIDs: S) throws -> [Int: JSONDict] where S.Element == Int {
        let ids = Array(Set(typeIDs))
        guard !ids.isEmpty else { return [:] }
        let db = try connect()
        let marks = placeholders(ids.count)
        var result: [Int: JSONDict] = [:]
        for row in try db.query("""
            SELECT t.type_id, t.name, t.category_id, t.portion_size, g.name AS group_name
            FROM types t LEFT JOIN groups g ON g.group_id = t.group_id
            WHERE t.type_id IN (\(marks))
            """, ids) {
            guard let id = row.int("type_id") else { continue }
            var info = row
            info["materials"] = [JSONDict]()
            result[id] = info
        }
        for m in try db.query("SELECT type_id, material_type_id, quantity FROM type_materials WHERE type_id IN (\(marks))", ids) {
            guard let id = m.int("type_id"), var info = result[id] else { continue }
            var materials = info["materials"] as? [JSONDict] ?? []
            materials.append(["material_type_id": m.int("material_type_id") ?? 0, "quantity": m.int("quantity") ?? 0])
            info["materials"] = materials
            result[id] = info
        }
        return result
    }

    /// {type_id: processing skill name} from CCP's data. Empty on an older database.
    static func reprocessSkills<S: Sequence>(_ typeIDs: S) -> [Int: String] where S.Element == Int {
        let ids = Array(Set(typeIDs))
        guard !ids.isEmpty, let db = try? connect(),
              let rows = try? db.query("""
                SELECT r.type_id, s.name FROM type_reprocess_skill r
                JOIN types s ON s.type_id = r.skill_type_id AND s.category_id = 16
                WHERE r.type_id IN (\(placeholders(ids.count)))
                """, ids) else { return [:] }
        var result: [Int: String] = [:]
        for row in rows {
            // Only trust it if it really is a processing skill.
            if let id = row.int("type_id"), let name = row.string("name"), name.hasSuffix("Processing") {
                result[id] = name
            }
        }
        return result
    }

    /// Skill type id by exact English name (category 16 = Skill).
    static func skillID(_ name: String) throws -> Int? {
        try connect().query("SELECT type_id FROM types WHERE name = ? AND category_id = 16 AND published = 1", [name])
            .first?.int("type_id")
    }

    static func blueprintForProduct(_ productTypeID: Int) throws -> Int? {
        try connect().query("SELECT blueprint_type_id FROM bp_manufacturing WHERE product_type_id = ?", [productTypeID])
            .first?.int("blueprint_type_id")
    }

    /// {blueprint: {...}, materials: [...], skills: [...]} or nil.
    static func manufacturing(_ blueprintTypeID: Int) throws -> JSONDict? {
        let db = try connect()
        guard let bp = try db.query("""
            SELECT m.*, p.name AS product_name, b.name AS blueprint_name,
                   p.group_id, g.name AS group_name, p.category_id
            FROM bp_manufacturing m
            JOIN types p ON p.type_id = m.product_type_id
            JOIN types b ON b.type_id = m.blueprint_type_id
            LEFT JOIN groups g ON g.group_id = p.group_id
            WHERE m.blueprint_type_id = ?
            """, [blueprintTypeID]).first else { return nil }
        let materials = try db.query("""
            SELECT bm.material_type_id, bm.quantity, t.name, t.volume
            FROM bp_materials bm JOIN types t ON t.type_id = bm.material_type_id
            WHERE bm.blueprint_type_id = ? ORDER BY bm.quantity DESC
            """, [blueprintTypeID])
        let skills = try db.query("""
            SELECT s.skill_type_id, s.level, t.name FROM bp_skills s
            JOIN types t ON t.type_id = s.skill_type_id WHERE s.blueprint_type_id = ?
            """, [blueprintTypeID])
        return ["blueprint": bp, "materials": materials, "skills": skills]
    }

    /// Every published skill with the group it sits in (Armor, Navigation, …), as in game.
    static func skillCatalog() throws -> [JSONDict] {
        try connect().query("""
            SELECT t.type_id, t.name, g.name AS group_name
            FROM types t JOIN groups g ON g.group_id = t.group_id
            WHERE t.category_id = ? AND t.published = 1
            ORDER BY g.name, t.name
            """, [skillCategory])
    }

    /// Published items that can be manufactured, matching text.
    static func searchProducts(_ text: String, limit: Int = 50) throws -> [JSONDict] {
        try connect().query("""
            SELECT m.blueprint_type_id, m.product_type_id, p.name AS product_name,
                   g.name AS group_name, p.meta_group_id
            FROM bp_manufacturing m
            JOIN types p ON p.type_id = m.product_type_id
            JOIN types b ON b.type_id = m.blueprint_type_id
            LEFT JOIN groups g ON g.group_id = p.group_id
            WHERE p.published = 1 AND b.published = 1 AND p.name LIKE ?
            ORDER BY (p.name = ?) DESC, length(p.name), p.name
            LIMIT ?
            """, ["%\(text)%", text, limit])
    }

    /// Everything buildable in one category / group (blueprints sold on the market, or T2/T3), A–Z.
    static func productsInGroup(category: String, group: String, limit: Int = 500) throws -> [JSONDict] {
        var filters = ""
        var params: [Any?] = []
        if !category.isEmpty { filters += " AND c.name = ?"; params.append(category) }
        if !group.isEmpty { filters += " AND g.name = ?"; params.append(group) }
        params.append(limit)
        return try connect().query("""
            SELECT m.blueprint_type_id, m.product_type_id, p.name AS product_name,
                   g.name AS group_name, p.meta_group_id
            FROM bp_manufacturing m
            JOIN types p ON p.type_id = m.product_type_id
            JOIN types b ON b.type_id = m.blueprint_type_id
            JOIN groups g ON g.group_id = p.group_id
            JOIN categories c ON c.category_id = p.category_id
            WHERE p.published = 1 AND b.published = 1
              AND (b.market_group_id IS NOT NULL OR p.meta_group_id IN (2, 14))\(filters)
            ORDER BY p.name
            LIMIT ?
            """, params)
    }

    static func productsForBlueprints<S: Sequence>(_ blueprintTypeIDs: S) throws -> [JSONDict] where S.Element == Int {
        let ids = Array(Set(blueprintTypeIDs))
        guard !ids.isEmpty else { return [] }
        return try connect().query("""
            SELECT m.blueprint_type_id, m.product_type_id, p.name AS product_name,
                   g.name AS group_name, p.meta_group_id
            FROM bp_manufacturing m
            JOIN types p ON p.type_id = m.product_type_id
            LEFT JOIN groups g ON g.group_id = p.group_id
            WHERE m.blueprint_type_id IN (\(placeholders(ids.count)))
            ORDER BY p.name
            """, ids)
    }

    static func searchSystems(_ text: String, limit: Int = 25) throws -> [JSONDict] {
        try connect().query("""
            SELECT system_id, name, security, region_id, region_name FROM solar_systems
            WHERE name LIKE ? ORDER BY (name = ?) DESC, length(name), name LIMIT ?
            """, ["\(text)%", text, limit])
    }

    static func system(_ systemID: Int) throws -> JSONDict? {
        try connect().query("SELECT * FROM solar_systems WHERE system_id = ?", [systemID]).first
    }
}

/// sde.py's _status + _lock.
actor SDEState {
    static let shared = SDEState()

    private var state = "unknown"
    private var message = ""
    private var build: String?
    private var running = false

    func begin() -> Bool {
        if running { return false }
        running = true
        return true
    }

    func end() { running = false }

    func set(state: String, message: String, build: String?, keepBuild: Bool = false) {
        self.state = state
        self.message = message
        if !keepBuild { self.build = build }
    }

    func status() -> JSONDict {
        if state == "unknown" {
            if let installed = SDE.installedBuild() {
                state = "ready"
                build = installed
            } else {
                state = "missing"
                message = "Static data not downloaded yet."
            }
        }
        return ["state": state, "message": message, "build": build as Any]
    }
}
