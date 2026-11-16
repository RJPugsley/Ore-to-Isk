import SwiftUI

/// Settings window (⌘,): EVE Online login.
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var loggedInAs: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Character") {
                    HStack {
                        Text(loggedInAs ?? appState.character?.name ?? "Not logged in")
                        if loggedInAs != nil {
                            Button("Log Out") {
                                Task {
                                    await appState.logOut()
                                    loggedInAs = nil
                                }
                            }
                        }
                    }
                }
                Button("Log In with EVE Online…") {
                    appState.openLogin()
                }
                LabeledContent("EVE application") {
                    Text(credentialsLabel)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            } header: {
                Text("EVE Online Login")
            } footer: {
                Text("You log in on EVE Online's own page – the app never sees your password. The login is kept in your Mac's Keychain (\"\(Keychain.service)\"), for your macOS user only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Ask Before Deleting Again") {
                    Confirm.resetAll()
                    ActivityCenter.shared.flash("Deletes will ask first again ✓")
                }
            } header: {
                Text("Confirmations")
            } footer: {
                Text("Brings back every \"Are you sure?\" you turned off with \"Don't ask again\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Start Fresh…") {
                    Task { await FirstRun.startFresh(appState) }
                }
            } header: {
                Text("Start Fresh")
            } footer: {
                Text("Logs out, forgets every setting and puts the app's data aside, then quits – the next launch is like a brand-new download. Your old data is kept in a folder next to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
        .task {
            loggedInAs = await EveAuth.shared.characterName()
        }
        .onChange(of: appState.characterID) {
            Task { loggedInAs = await EveAuth.shared.characterName() }
        }
    }

    private var credentialsLabel: String {
        do {
            _ = try EveCredentials.load()
            return "Built in (EVE: Ore to ISK)"
        } catch {
            return error.localizedDescription
        }
    }
}
