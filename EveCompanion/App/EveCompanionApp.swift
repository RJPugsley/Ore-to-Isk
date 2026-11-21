import SwiftUI

enum OreDatabaseWindow {
    static let id = "ore-database"
}

/// Window menu item: opens (or brings forward) the Ore Database window.
struct OpenOreDatabaseButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Ore Database") { openWindow(id: OreDatabaseWindow.id) }
            .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}

@main
struct EveCompanionApp: App {
    @State private var appState = AppState()

    /// macOS waits about 1 second before showing a tooltip; this app uses 75% of that.
    static let tooltipDelayMilliseconds = 750

    init() {
        // AppKit reads this (milliseconds) from the app's own defaults when it shows tooltips.
        UserDefaults.standard.set(Self.tooltipDelayMilliseconds, forKey: "NSInitialToolTipDelay")
        // No web cache on disk (it would go to ~/Library/Caches): the app keeps its own copies
        // of what it fetches in Application Support/eve_ore_to_isk.
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 0, directory: nil)
        Self.moveOldSettings()
    }

    /// The Ore Planner became the Build Planner (15 Nov 2026): carry its saved settings
    /// (your plan, areas, tick boxes) over to the new names once, then forget the old ones.
    private static func moveOldSettings() {
        let defaults = UserDefaults.standard
        for name in ["items", "spaces", "subtractStock", "breakDown", "ownedOnly", "category", "group"] {
            let old = "orePlanner.\(name)"
            let new = "buildPlanner.\(name)"
            if let value = defaults.object(forKey: old) {
                if defaults.object(forKey: new) == nil { defaults.set(value, forKey: new) }
                defaults.removeObject(forKey: old)
            }
        }
    }

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandMenu("Character") {
                Button("Refresh") {
                    Task { await appState.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isLoading)

                Divider()

                Button("Log In with EVE Online…") {
                    appState.openLogin()
                }
            }

            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }

            // Help menu: the built-in, searchable help (Views/HelpView.swift, articles in Resources/Help).
            CommandGroup(replacing: .help) {
                HelpMenuButtons()
            }

            CommandGroup(before: .windowList) {
                OpenOreDatabaseButton()
                Divider()
            }
        }

        // Ore Database in its own window, to keep open beside the main one for quick reference.
        Window("Ore Database", id: OreDatabaseWindow.id) {
            NavigationStack {
                OreDatabaseView()
            }
            .environment(appState)
            .frame(minWidth: 560, minHeight: 360)
        }
        .defaultSize(width: 780, height: 640)

        // Help window: contents, A–Z index and search over every article.
        Window("\(AppInfo.name) Help", id: HelpWindow.id) {
            HelpView()
                .environment(appState)
                .frame(minWidth: 700, minHeight: 480)
        }
        .defaultSize(width: 980, height: 720)

        // About window: name, version (v1.4 beta), data folder, CCP notice.
        Window("About \(AppInfo.name)", id: AboutView.id) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}


/// "About EVE: Ore to ISK" in the app menu – opens our About window.
private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About \(AppInfo.name)") { openWindow(id: AboutView.id) }
    }
}
