import Charts
import SwiftUI

// MARK: - Models (/character/summary)

struct CharacterSummary: Decodable {
    let characterId: Int
    let name: String?
    let corporation: String?
    let alliance: String?
    let securityStatus: Double?
    let playingFor: String?
    let wallet: Double?
    let homeStation: HomeStation?
    let location: CurrentLocation?
    let ship: CurrentShip?
    let missingScopes: [String]
}

struct HomeStation: Decodable {
    let locationId: Int
    let name: String?
}

struct CurrentLocation: Decodable {
    let systemId: Int
    let system: String
    let security: Double?
    let region: String?
    let dockedAt: String?
    let dockedId: Int?
}

struct CurrentShip: Decodable {
    let name: String?
    let typeId: Int
    let typeName: String?
}

/// Security as the game shows it: one decimal, and anything between 0.0 and 0.05 shows as 0.1.
func securityLabel(_ value: Double) -> String {
    let shown = (value > 0 && value < 0.05) ? 0.1 : (value * 10).rounded() / 10
    return shown.formatted(.number.precision(.fractionLength(1)))
}

func securityColor(_ value: Double) -> Color {
    switch (value * 10).rounded() / 10 {
    case 0.5...: .green
    case 0.1..<0.5: .orange
    default: .red
    }
}

// MARK: - View

/// Character summary – who you are and where you are right now. Shown under your character's name.
struct DashboardView: View {
    @Environment(AppState.self) private var appState

    @State private var summary: CharacterSummary?
    @State private var worth: [NetWorthPoint] = []
    @AppStorage(HistoryRange.key) private var rangeDays = HistoryRange.defaultDays
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                header
            }

            if let summary {
                Section {
                    LabeledContent("Wallet") {
                        if let wallet = summary.wallet {
                            Text(wallet.isk).bold().monospacedDigit()
                        } else {
                            needsPermission
                        }
                    }
                    let points = worth.filter { $0.total != nil }
                    if points.count >= 2, let first = points.first?.total, let last = points.last?.total {
                        LabeledContent("Net worth · \(HistoryRange.label(rangeDays))") {
                            // Value, with the growth over the chosen History range under it (bottom right).
                            let change: Double? = first > 0 ? (last - first) / first * 100 : nil
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(last.iskShort).monospacedDigit()
                                if let change {
                                    Label(String(format: "%+.2f%%", change),
                                          systemImage: change > 0 ? "arrow.up.right" : (change < 0 ? "arrow.down.right" : "arrow.right"))
                                        .font(.caption).monospacedDigit()
                                        .foregroundStyle(change > 0 ? Color.green : (change < 0 ? Color.red : Color.secondary))
                                }
                            }
                            .help("From \(first.iskShort) on \(points.first?.date ?? "") to \(last.iskShort) now (wallet + items + orders)")
                        }
                    }
                    LabeledContent("Home station") {
                        if let home = summary.homeStation {
                            Text(home.name ?? "Unknown").textSelection(.enabled)
                                .contextMenu { PlaceMenu(locationID: home.locationId, name: home.name ?? "Home station") }
                        } else {
                            needsPermission
                        }
                    }
                    LabeledContent("Playing for") {
                        Text(summary.playingFor ?? "–")
                    }
                    LabeledContent("Security status") {
                        if let sec = summary.securityStatus {
                            Text(sec, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .foregroundStyle(sec >= 0 ? Color.green : Color.red)
                        } else {
                            Text("–")
                        }
                    }
                    LabeledContent("Corporation") {
                        Text(summary.corporation ?? "–")
                    }
                    if let alliance = summary.alliance {
                        LabeledContent("Alliance") { Text(alliance) }
                    }
                }

                Section("Right Now") {
                    LabeledContent("Location") {
                        if let location = summary.location {
                            VStack(alignment: .trailing, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(location.system).bold()
                                    if let sec = location.security {
                                        Text(securityLabel(sec))
                                            .monospacedDigit()
                                            .foregroundStyle(securityColor(sec))
                                    }
                                    if let region = location.region {
                                        Text("· \(region)").foregroundStyle(.secondary)
                                    }
                                }
                                Text(location.dockedAt.map { "Docked at \($0)" } ?? "In space")
                                    .contextMenu {
                                        if let dock = location.dockedId, let name = location.dockedAt {
                                            PlaceMenu(locationID: dock, name: name, systemID: location.systemId, systemName: location.system)
                                        }
                                        PlaceMenu(locationID: location.systemId, name: location.system)
                                    }
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            needsPermission
                        }
                    }
                    LabeledContent("Ship") {
                        if let ship = summary.ship {
                            HStack(spacing: 8) {
                                AsyncImage(url: PublicESIClient.typeIconURL(typeID: ship.typeId, size: 32)) { image in
                                    image.resizable()
                                } placeholder: { Color.clear }
                                .frame(width: 22, height: 22)
                                Text(ship.name ?? "").bold()
                                Text(ship.typeName ?? "").foregroundStyle(.secondary)
                            }
                            .contextMenu { ItemMenu(typeID: ship.typeId, name: ship.typeName ?? "Ship") }
                        } else {
                            needsPermission
                        }
                    }
                }

                if !summary.missingScopes.isEmpty {
                    Section {
                        Label("Some details need extra permission. Use Character → Login to approve: \(summary.missingScopes.joined(separator: ", "))",
                              systemImage: "lock")
                            .foregroundStyle(.orange)
                    }
                }
            } else if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .task(id: rangeDays) { worth = (try? await appState.backend.netWorthHistory()) ?? [] }
        .task {
            // Location and ship change as you play – check again every minute.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    private var needsPermission: some View {
        Text("Needs permission").foregroundStyle(.orange)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            if let id = appState.characterID {
                AsyncImage(url: PublicESIClient.portraitURL(characterID: id, size: 256)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.square")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(summary?.name ?? appState.character?.name ?? "Loading…")
                    .font(.title)
                    .bold()
                if let corp = summary?.corporation ?? appState.corporationName {
                    Text([corp, summary?.alliance].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        do {
            summary = try await appState.backend.characterSummary()
            errorMessage = nil
        } catch {
            if summary == nil { errorMessage = error.localizedDescription }
        }
    }
}
