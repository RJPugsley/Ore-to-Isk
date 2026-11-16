import AppKit
import SwiftUI

/// First run (16 Nov 2026): a short welcome – log in, then tell the app where you build,
/// trade and refine. Shown until finished or skipped; "Start Fresh" in Settings brings it back.
enum FirstRun {
    static let doneKey = "setup.done"

    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    static func finish() { UserDefaults.standard.set(true, forKey: doneKey) }

    /// Settings → Start Fresh: log out, put the app's data folder aside, forget every setting,
    /// then quit – the next launch is exactly like a brand-new download.
    @MainActor
    static func startFresh(_ appState: AppState) async {
        let alert = NSAlert()
        alert.messageText = "Start Fresh?"
        alert.informativeText = """
        The app logs out, forgets all its settings (hubs, refinery, plans, watch lists) and puts its data \
        folder aside, then quits. When you open it again it's like a brand-new download: welcome screen, \
        game data download, log in.

        Your old data folder is kept next to the new one as "\(EngineSettings.folderName) (before reset …)" \
        – delete it in Finder once you're sure you don't need it.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Start Fresh and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        await appState.logOut()
        let fm = FileManager.default
        let folder = EngineSettings.appFolder
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: Date())
        let aside = folder.deletingLastPathComponent()
            .appending(path: "\(EngineSettings.folderName) (before reset \(stamp))", directoryHint: .isDirectory)
        try? fm.moveItem(at: folder, to: aside)
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            UserDefaults.standard.synchronize()
        }
        NSApp.terminate(nil)
    }
}

struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var step = 1

    var body: some View {
        VStack(spacing: 0) {
            if step == 1 {
                welcome
            } else {
                setup
            }
            Divider()
            HStack {
                Button("Open Help") {
                    HelpCenter.shared.show("welcome")
                    openWindow(id: HelpWindow.id)
                }
                Spacer()
                if step == 1 {
                    Button("Skip Setup") { finish() }
                    Button("Next") { step = 2 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Back") { step = 1 }
                    Button("Done") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
        .frame(width: 640, height: step == 1 ? 520 : 680)
    }

    private func finish() {
        FirstRun.finish()
        dismiss()
    }

    // MARK: Step 1 – welcome + log in

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Welcome to \(AppInfo.name)")
                .font(.largeTitle.bold())
            Text("Mine, refine, build, sell and haul – see what pays before you undock.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Label("**Pilot** – your character, skills and money", systemImage: "person.crop.circle")
                Label("**Mine** – what to mine, and whether to reprocess it", systemImage: "cube.transparent")
                Label("**Build** – what to build and what it really earns", systemImage: "hammer")
                Label("**Sell** – prices at the five trade hubs and your orders", systemImage: "cart")
                Label("**Haul** – pack your trips and fly the safe way", systemImage: "shippingbox")
            }
            .padding(.vertical, 4)

            GroupBox {
                HStack(spacing: 12) {
                    if let name = appState.character?.name {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text("Logged in as **\(name)**")
                        Spacer()
                    } else {
                        Image(systemName: "person.badge.key")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Log in with your EVE character")
                                .fontWeight(.medium)
                            Text("On EVE Online's own page – the app never sees your password.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Log In with EVE Online…") { appState.openLogin() }
                    }
                }
                .padding(6)
            }
            if let error = appState.authError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Step 2 – where you build, trade and refine

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Setup")
                .font(.title.bold())
            Text("Tell the app where you build, which hub you trade at and where you refine ore. You can change all of this later with **Build Settings** on the Manufacturing or Reprocessing page.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !appState.isAuthenticated {
                Label("Log in first (step 1) to pick your own stations, containers and refinery.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            BuildSettingsView()
                .environment(appState)
                .id(appState.characterID ?? 0)      // reload your stations after logging in
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }
}
