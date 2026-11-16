import Foundation

/// Engine-wide settings (originally Backend/config.py).
enum EngineSettings {
    static let userAgent = "EVE-Ore-to-ISK/1.0 (macOS)"

    /// ESI permissions requested at login.
    static let scopes: [String] = [
        "esi-skills.read_skills.v1",
        "esi-skills.read_skillqueue.v1",
        "esi-wallet.read_character_wallet.v1",
        "esi-clones.read_clones.v1",
        "esi-universe.read_structures.v1",
        "esi-assets.read_assets.v1",
        "esi-characters.read_standings.v1",
        "esi-industry.read_character_jobs.v1",
        "esi-markets.read_character_orders.v1",
        "esi-characters.read_blueprints.v1",
        "esi-contracts.read_character_contracts.v1",
        "esi-clones.read_implants.v1",
        "esi-industry.read_character_mining.v1",
        "esi-location.read_location.v1",
        "esi-location.read_ship_type.v1",
        "esi-ui.write_waypoint.v1",   // Haul › Route: send a route to the game (15 Nov 2026)
        "esi-search.search_structures.v1",   // Haul › Route: find stations / structures you can dock at
        "esi-ui.open_window.v1",   // right-click › Show in game (market details, info windows)
    ]

    /// Folder name on disk (the app is shown as "EVE: Ore to ISK").
    static let folderName = "eve_ore_to_isk"

    /// Everything the app saves: ~/Library/Application Support/eve_ore_to_isk
    /// (Data/ = history + EVE static data, Config/ = your own ore_locations.json if you make one).
    static let appFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support")
        let folder = base.appending(path: folderName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder.appending(path: "Data"), withIntermediateDirectories: true)
        return folder
    }()
}

/// The EVE application the app logs in with: the app's own **public** application on
/// developers.eveonline.com (PKCE – no secret anywhere). Any player logs in with their own
/// character; nothing about anyone's login ships in the app. (The old developer login –
/// Config/.env with a client secret and a local callback server – was removed 16 Nov 2026.)
struct EveCredentials {
    let clientID: String
    let callbackURL: URL

    /// "EVE: Ore to ISK" on developers.eveonline.com (created 16 Nov 2026). Public, not a secret.
    static let publicClientID = "3739c699335444d7ad1857c66a33a1c7"
    /// The app's own URL scheme; the login window catches it. EVE only allows custom schemes starting "eveauth".
    static let publicCallback = "eveauth-oretoisk://callback"

    static func load() throws -> EveCredentials {
        EveCredentials(clientID: publicClientID, callbackURL: URL(string: publicCallback)!)
    }
}

extension Data {
    /// Decodes base64url (JWT) text, padding added as needed.
    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
