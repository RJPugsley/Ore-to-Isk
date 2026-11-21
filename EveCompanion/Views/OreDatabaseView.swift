import SwiftUI

/// Every ore and ice in the game and what it reprocesses into. Search by ore, family or mineral.
struct OreDatabaseView: View {
    @State private var highlight = RowHighlights()
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    @State private var ores: [OreCatalogEntry] = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var sortOrder = [KeyPathComparator(\OreCatalogEntry.family), KeyPathComparator(\OreCatalogEntry.name)]
    @AppStorage("oreDatabase.useMyYield") private var useMyYield = true

    // Refinery readings from Build Settings – reload when they change.
    @AppStorage(BuildSettingsKey.oreYield) private var oreYield = BuildSettingsKey.defaultOreYield
    @AppStorage(BuildSettingsKey.oreYieldSkill) private var oreYieldSkill = BuildSettingsKey.defaultOreYieldSkill
    @AppStorage(BuildSettingsKey.iceYield) private var iceYield = BuildSettingsKey.defaultIceYield

    private var yieldKey: String { "\(oreYield)|\(oreYieldSkill)|\(iceYield)" }

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    private var filtered: [OreCatalogEntry] {
        ores
            .filter { !$0.compressed }   // only what you mine; compression happens at the refinery
            .filter { ore in
                query.isEmpty
                    || ore.name.localizedCaseInsensitiveContains(query)
                    || ore.family.localizedCaseInsensitiveContains(query)
                    || ore.outputs.contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if ores.isEmpty {
                if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't Load Ores", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ProgressView("Loading every ore in the game…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Table(filtered, selection: highlight.row("t51"), sortOrder: $sortOrder) {
                    TableColumn("Ore", value: \.name) { ore in
                        HStack(spacing: 6) {
                            AsyncImage(url: PublicESIClient.typeIconURL(typeID: ore.typeId, size: 32)) { image in
                                image.resizable()
                            } placeholder: { Color.clear }
                            .frame(width: 18, height: 18)
                            Text(ore.name)
                        }
                        .help("\(ore.family) · amounts are per \((ore.portionSize ?? 1).short) units" + (useMyYield ? ", after your yield" : ", before your yield (game base)"))
                    }
                    .width(min: 160, ideal: 230)

                    TableColumn("Yield", value: \.yieldSort) { ore in
                        Text(ore.yield?.percent ?? "–")
                            .monospacedDigit()
                            .foregroundStyle(useMyYield ? Color.primary : Color.secondary)
                            .help("Your yield at the refinery: its bonus × Reprocessing, Reprocessing Efficiency and \(ore.skill ?? "the ore's processing skill"). Set the refinery readings in Build Settings.")
                    }
                    .width(min: 50, ideal: 60)

                    TableColumn("Most Produced", value: \.firstOutput) { ore in
                        output(ore, 0)
                    }
                    TableColumn("Second", value: \.secondOutput) { ore in
                        output(ore, 1)
                    }
                    TableColumn("Third", value: \.thirdOutput) { ore in
                        output(ore, 2)
                    }
                    TableColumn("Also", value: \.otherOutputs) { ore in
                        highlighted(ore.otherOutputsWithAmounts(yours: useMyYield))
                            .help("Only ice, Spodumain and a few moon ores produce more than three materials.")
                    }
                    TableColumn("Found In", value: \.securitySort) { ore in
                        Text(ore.foundIn)
                            .monospacedDigit()
                            .foregroundStyle(ore.spaceColor)
                            .help(ore.locationNote ?? "No location data – add it to Config/ore_locations.json")
                    }
                    .width(min: 80, ideal: 100)
                }
                .contextMenu(forSelectionType: OreCatalogEntry.ID.self) { ids in
                    if let id = ids.first, let ore = filtered.first(where: { $0.id == id }) {
                        ItemMenu(typeID: ore.typeId, name: ore.name)
                        Button("Plan Mining in the Build Planner") { appState.goToPage = .buildPlanner }
                    }
                }
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Ore or mineral, e.g. Mexallon")
        .searchSuggestions {
            ForEach(localSuggestions(searchText, from: ores.filter { !$0.compressed }.map(\.name) + ores.flatMap(\.outputs)), id: \.self) { name in
                Text(name).searchCompletion(name)
            }
        }
        .navigationSubtitle(ores.isEmpty ? "" : "\(filtered.count) ores")
        .toolbar {
            ToolbarItem {
                Button {
                    openWindow(id: OreDatabaseWindow.id)
                } label: {
                    Label("Open in Own Window", systemImage: "macwindow.on.rectangle")
                }
                .help("Open the Ore Database in its own window (⇧⌘O)")
            }
            ToolbarItem {
                Toggle("My Yield", isOn: $useMyYield)
                    .toggleStyle(.checkbox)
                    .help("On: what you'd actually get reprocessing at your refinery with your skills. Off: the game's base amounts (Industry tab).")
            }
        }
        .task(id: yieldKey) { await load() }
    }

    /// The material you searched for is shown bold in the accent colour.
    /// "Tritanium 150": material name (highlighted when it matches the search) then the game's amount.
    private func output(_ ore: OreCatalogEntry, _ index: Int) -> Text {
        guard index < ore.outputs.count else { return Text("") }
        let name = highlighted(ore.outputs[index])
        guard let amount = ore.amount(at: index, yours: useMyYield) else { return name }
        return name + Text("  \(amount.short)").foregroundStyle(.secondary)
    }

    private func highlighted(_ name: String) -> Text {
        if !query.isEmpty && !name.isEmpty && name.localizedCaseInsensitiveContains(query) {
            return Text(name).bold().foregroundStyle(Color.accentColor)
        }
        return Text(name)
    }

    private func load() async {
        do {
            ores = try await appState.backend.oreCatalog(BuildSettingsKey.refineryQuery())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Outputs are already ordered most-produced first by the backend.
extension OreCatalogEntry {
    var firstOutput: String { outputs.count > 0 ? outputs[0] : "" }
    var secondOutput: String { outputs.count > 1 ? outputs[1] : "" }
    var thirdOutput: String { outputs.count > 2 ? outputs[2] : "" }
    var otherOutputs: String { outputs.count > 3 ? outputs[3...].joined(separator: ", ") : "" }

    var yieldSort: Double { yield ?? 0 }

    /// Amount of output `index` per portion: yours after reprocessing yield, or the game's base.
    func amount(at index: Int, yours: Bool) -> Int? {
        let list = (yours ? yourQuantities : nil) ?? outputQuantities
        guard let list, index < list.count else { return nil }
        return list[index]
    }

    func otherOutputsWithAmounts(yours: Bool) -> String {
        guard outputs.count > 3 else { return "" }
        return outputs.indices.dropFirst(3).map { index in
            amount(at: index, yours: yours).map { "\(outputs[index]) \($0.short)" } ?? outputs[index]
        }.joined(separator: ", ")
    }

    /// "1.0 · High", "-0.5 · Null", "Moon", or "?" when unknown.
    var foundIn: String {
        guard let space else { return "?" }
        guard let security else { return space }
        return "\(String(format: "%.1f", security)) · \(space)"
    }

    /// Sort safest first; unknown at the bottom.
    var securitySort: Double { security ?? -99 }

    var spaceColor: Color {
        switch space {
        case "High": Color.green
        case "Low": Color.orange
        case "Null": Color.red
        case "Pochven": Color.purple
        default: Color.secondary
        }
    }
}
