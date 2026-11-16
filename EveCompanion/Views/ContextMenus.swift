import AppKit
import SwiftUI

// MARK: - Right-click menus used all over the app
//
// ItemMenu  – anything with a type: ships, ore, minerals, products, blueprints' products.
// PlaceMenu – systems, NPC stations, player structures.
// Confirm   – every delete asks first, with "Don't ask again".

/// "Are you sure?" for deletes – with a "Don't ask again" tick box. Returns true to go ahead.
@MainActor
enum Confirm {
    static func delete(_ key: String, title: String, message: String, button: String = "Delete") -> Bool {
        let skipKey = "confirm.skip.\(key)"
        if UserDefaults.standard.bool(forKey: skipKey) { return true }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed && alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: skipKey)
        }
        return confirmed
    }

    /// Settings › "Ask before deleting again".
    static func resetAll() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("confirm.skip.") {
            defaults.removeObject(forKey: key)
        }
    }
}

@MainActor func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    ActivityCenter.shared.flash("Copied ✓")
}

/// Right-click menu for an item. Shows only what makes sense for it (no Manufacturing for ore).
struct ItemMenu: View {
    @Environment(AppState.self) private var appState

    let typeID: Int
    let name: String
    /// Set for a stack – adds "Copy for Multibuy".
    var quantity: Int? = nil
    /// Leave out the "Show in Market" line (when you're already on its market page).
    var hideMarket = false

    var body: some View {
        let blueprint = appState.blueprintForProduct[typeID]
        Section(name) {
            if !hideMarket {
                Button("Show in Market") { appState.showInMarket(typeID) }
            }
            if let blueprint {
                Button("Build vs Sell") { appState.open(.buildVsSell(name: name)) }
                Button("Manufacturing") { appState.open(.manufacturing(blueprintTypeID: blueprint, name: name)) }
                Button("Add to Build Planner") { appState.addToBuildPlanner(blueprintTypeID: blueprint, name: name) }
                Button("Blueprint Payback") { appState.open(.payback(name: name)) }
            }
        }
        Section("In EVE") {
            Button("Show Market Details in Game") { appState.showInGame(typeID, market: true, name: name) }
            Button("Show Info in Game") { appState.showInGame(typeID, market: false, name: name) }
        }
        Section {
            if appState.watchedTypes.contains(typeID) {
                Button("Remove from Market Watchlist") {
                    if Confirm.delete("marketWatch", title: "Remove \(name) from your Market Watchlist?",
                                      message: "You can add it back from any right-click menu.", button: "Remove") {
                        appState.toggleWatch(typeID, name: name)
                    }
                }
            } else {
                Button("Add to Market Watchlist") { appState.toggleWatch(typeID, name: name) }
            }
            Button("Copy Name") { copyToClipboard(name) }
            if let quantity {
                Button("Copy for Multibuy") { copyToClipboard("\(name) \(quantity)") }
            }
            if let url = URL(string: "https://everef.net/type/\(typeID)") {
                Link("Open on EVE Ref", destination: url)
            }
        }
    }
}

/// Right-click menu for a place. `systemID` / `systemName` let a station offer system things
/// (avoid, Dotlan, zKillboard) too.
struct PlaceMenu: View {
    @Environment(AppState.self) private var appState

    let locationID: Int
    let name: String
    var systemID: Int? = nil
    var systemName: String? = nil

    private var isSystem: Bool { (30_000_000..<33_000_000).contains(locationID) }
    private var system: Int? { isSystem ? locationID : systemID }
    private var systemLabel: String? { isSystem ? name : systemName }

    var body: some View {
        Section(name) {
            Button("Route from Here") { appState.routeFrom(locationID, name: name) }
            Button("Route to Here") { appState.routeTo(locationID, name: name) }
            Button("Add as a Stop on the Route") { appState.addStop(locationID, name: name) }
            if let system, let systemLabel {
                Button("Avoid \(systemLabel)") { appState.avoidSystem(system, name: systemLabel) }
            }
        }
        Section("In EVE") {
            Button("Set Destination in Game") { appState.setDestination(locationID, name: name, clear: true) }
            Button("Add Waypoint in Game") { appState.setDestination(locationID, name: name, clear: false) }
            Button("Show Info in Game") { appState.showInGame(locationID, market: false, name: name) }
        }
        Section {
            Button("Copy Name") { copyToClipboard(name) }
            if let systemLabel, let url = URL(string: "https://evemaps.dotlan.net/system/\(systemLabel.replacingOccurrences(of: " ", with: "_"))") {
                Link("Map on Dotlan", destination: url)
            }
            if let system, let url = URL(string: "https://zkillboard.com/system/\(system)/") {
                Link("Kills on zKillboard", destination: url)
            }
        }
    }
}

/// The five trade hubs' stations and systems – for menus on hub rows.
extension TradeHub {
    static func place(_ name: String) -> (station: Int, system: Int, systemName: String)? {
        switch name.lowercased() {
        case "jita": return (60003760, 30000142, "Jita")
        case "amarr": return (60008494, 30002187, "Amarr")
        case "dodixie": return (60011866, 30002659, "Dodixie")
        case "rens": return (60004588, 30002510, "Rens")
        case "hek": return (60005686, 30002053, "Hek")
        default: return nil
        }
    }
}
