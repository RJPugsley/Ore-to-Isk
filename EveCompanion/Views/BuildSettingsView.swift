import SwiftUI

/// UserDefaults keys for build settings, shared by the calculator and the settings panel.
enum BuildSettingsKey {
    static let systemId = "build.systemId"
    static let systemName = "build.systemName"
    static let structure = "build.structure"
    static let rigME = "build.rigME"
    static let rigTE = "build.rigTE"
    static let facilityTax = "build.facilityTax"
    static let materialHub = "build.materialHub"
    static let materialPrice = "build.materialPrice"          // Reprocessing page: valuing ore/minerals to sell
    /// Manufacturing: how materials are costed. "sell" = what buying them costs (hub sell orders).
    static let materialCostBasis = "build.materialCostBasis"
    static let useOwned = "build.useOwned"
    static let stockLocationId = "build.stockLocationId"
    static let stockLocationName = "build.stockLocationName"

    // Refinery (reprocessing) – calibrated from the yield the game shows you.
    static let refineryId = "refinery.locationId"
    static let refineryName = "refinery.locationName"
    static let oreYield = "refinery.oreYield"
    static let oreYieldSkill = "refinery.oreYieldSkill"
    static let iceYield = "refinery.iceYield"
    static let refineryTax = "refinery.tax"
    static let useOre = "refinery.useOre"

    // Nothing measured yet: 0 = assume a plain NPC refinery (50% before skills) until the
    // player types in the yield their own refinery shows.
    static let defaultOreYield = 0.0
    static let defaultOreYieldSkill = "Simple Ore Processing"
    static let defaultIceYield = 0.0
    static let defaultRefineryTax = 0.0

    struct OreFamily: Hashable {
        let skill: String
        let label: String
    }

    static let oreFamilies: [OreFamily] = [
        OreFamily(skill: "Simple Ore Processing", label: "Simple (Veldspar, Scordite, Pyroxeres, Plagioclase…)"),
        OreFamily(skill: "Coherent Ore Processing", label: "Coherent (Omber, Kernite, Jaspet, Ytirium…)"),
        OreFamily(skill: "Variegated Ore Processing", label: "Variegated (Dark Ochre, Gneiss, Crokite…)"),
        OreFamily(skill: "Complex Ore Processing", label: "Complex (Bistot, Arkonor, Spodumain…)"),
    ]

    /// Refinery calibration as backend query parameters (shared by calculator & reprocessing page).
    static func refineryQuery() -> [URLQueryItem] {
        let defaults = UserDefaults.standard
        func double(_ key: String, _ fallback: Double) -> Double {
            (defaults.object(forKey: key) as? Double) ?? fallback
        }
        return [
            URLQueryItem(name: "ore_yield", value: String(double(oreYield, defaultOreYield))),
            URLQueryItem(name: "ore_skill", value: defaults.string(forKey: oreYieldSkill) ?? defaultOreYieldSkill),
            URLQueryItem(name: "ice_yield", value: String(double(iceYield, defaultIceYield))),
            URLQueryItem(name: "refinery_tax", value: String(double(refineryTax, defaultRefineryTax))),
        ]
    }

    // Neutral defaults for a new player: build in Jita (NPC station), prices from Jita.
    // The first-run setup (WelcomeView) asks for their own.
    static let defaultSystemId = 30000142
    static let defaultSystemName = "Jita"
    static let defaultHub = TradeHub.Jita.rawValue
}

/// Inspector panel: where you build and how materials are priced.
struct BuildSettingsView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(BuildSettingsKey.systemId) private var systemId = BuildSettingsKey.defaultSystemId
    @AppStorage(BuildSettingsKey.systemName) private var systemName = BuildSettingsKey.defaultSystemName
    @AppStorage(BuildSettingsKey.structure) private var structure = StructureKind.npc.rawValue
    @AppStorage(BuildSettingsKey.rigME) private var rigME = 0.0
    @AppStorage(BuildSettingsKey.rigTE) private var rigTE = 0.0
    @AppStorage(BuildSettingsKey.facilityTax) private var facilityTax = 0.25
    @AppStorage(BuildSettingsKey.materialHub) private var materialHub = BuildSettingsKey.defaultHub
    @AppStorage(BuildSettingsKey.materialCostBasis) private var materialPrice = "sell"
    @AppStorage(BuildSettingsKey.useOwned) private var useOwned = true
    @AppStorage(BuildSettingsKey.stockLocationId) private var stockLocationId = 0
    @AppStorage(BuildSettingsKey.stockLocationName) private var stockLocationName = ""
    @State private var stockLocations: [StockLocation] = []

    @AppStorage(BuildSettingsKey.refineryId) private var refineryId = 0
    @AppStorage(BuildSettingsKey.refineryName) private var refineryName = ""
    @AppStorage(BuildSettingsKey.oreYield) private var oreYield = BuildSettingsKey.defaultOreYield
    @AppStorage(BuildSettingsKey.oreYieldSkill) private var oreYieldSkill = BuildSettingsKey.defaultOreYieldSkill
    @AppStorage(BuildSettingsKey.iceYield) private var iceYield = BuildSettingsKey.defaultIceYield
    @AppStorage(BuildSettingsKey.refineryTax) private var refineryTax = BuildSettingsKey.defaultRefineryTax
    @AppStorage(BuildSettingsKey.useOre) private var useOre = true

    @State private var systemSearch = ""
    @State private var systemResults: [SolarSystem] = []

    var body: some View {
        Form {
            Section {
                LabeledContent("System") {
                    Text(systemName.isEmpty ? "None" : systemName)
                        .fontWeight(.medium)
                }

                TextField("Change system", text: $systemSearch, prompt: Text("Type a system name"))

                ForEach(systemResults) { system in
                    Button {
                        systemId = system.systemId
                        systemName = system.name
                        systemSearch = ""
                        systemResults = []
                    } label: {
                        HStack {
                            Text(system.name)
                            Spacer()
                            Text("\(system.securityLabel)  \(system.regionName ?? "")")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Picker("Facility", selection: $structure) {
                    ForEach(StructureKind.allCases) { kind in
                        Text(kind.title).tag(kind.rawValue)
                    }
                }

                if structure != StructureKind.npc.rawValue {
                    TextField("Rig material bonus %", value: $rigME, format: .number)
                    TextField("Rig time bonus %", value: $rigTE, format: .number)
                }

                TextField("Facility tax %", value: $facilityTax, format: .number)
            } header: {
                Text("Build Location")
            } footer: {
                Text("NPC stations charge 0.25% facility tax. Player structures set their own. The system's cost index is fetched live from ESI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Price at", selection: $materialHub) {
                    ForEach(TradeHub.allCases) { hub in
                        Text(hub.rawValue).tag(hub.rawValue)
                    }
                }

                Picker("Cost materials at", selection: $materialPrice) {
                    Text("Sell orders – what buying them costs").tag("sell")
                    Text("Buy orders – what selling yours would get").tag("buy")
                }
                .pickerStyle(.radioGroup)

                Toggle("Use materials I already own", isOn: $useOwned)

                if useOwned {
                    Picker("Count stock at", selection: $stockLocationId) {
                        Text("Everywhere").tag(0)
                        if stockLocationId != 0 && !stockLocations.contains(where: { $0.locationId == stockLocationId }) {
                            Text(stockLocationName.isEmpty ? "Saved location" : stockLocationName).tag(stockLocationId)
                        }
                        Divider()
                        ForEach(stockLocations) { location in
                            Text(location.name).tag(location.locationId)
                        }
                    }
                    .onChange(of: stockLocationId) { _, newValue in
                        stockLocationName = stockLocations.first { $0.locationId == newValue }?.name ?? ""
                    }
                }
            } header: {
                Text("Material Prices")
            } footer: {
                Text("Profit (List) costs every material at what it would take to buy it at the hub (sell orders), plus the job fee. Cash Profit counts materials you already own as free and only charges for what you still have to buy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Refinery", selection: $refineryId) {
                    Text("None").tag(0)
                    if refineryId != 0 && !stockLocations.contains(where: { $0.locationId == refineryId }) {
                        Text(refineryName.isEmpty ? "Saved refinery" : refineryName).tag(refineryId)
                    }
                    Divider()
                    ForEach(stockLocations) { location in
                        Text(location.name).tag(location.locationId)
                    }
                }
                .onChange(of: refineryId) { _, newValue in
                    refineryName = stockLocations.first { $0.locationId == newValue }?.name ?? ""
                }

                TextField("Ore yield shown in game %", value: $oreYield, format: .number)
                Picker("…measured on", selection: $oreYieldSkill) {
                    ForEach(BuildSettingsKey.oreFamilies, id: \.skill) { family in
                        Text(family.label).tag(family.skill)
                    }
                }
                TextField("Ice yield shown in game %", value: $iceYield, format: .number)
                TextField("Refinery tax %", value: $refineryTax, format: .number)

                Toggle("Count ore at the refinery as minerals", isOn: $useOre)
                    .disabled(refineryId == 0 || !useOwned)
            } header: {
                Text("Refinery")
            } footer: {
                Text("Open the Reprocessing window at your refinery, drop in some ore and copy the yield % it shows. The app divides out your skills to get the refinery's own bonus, then applies it to every ore at your skill for that ore. Ice is read separately because refinery rigs are ore- or ice-specific. Leave a yield at 0 until you've measured it – the app then assumes a plain NPC station. Enter the tax the refinery charges, if any.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: structure) { _, newValue in
            if newValue == StructureKind.npc.rawValue {
                facilityTax = 0.25
                rigME = 0
                rigTE = 0
            }
        }
        .task {
            stockLocations = (try? await appState.backend.stockLocations()) ?? []
        }
        .task(id: systemSearch) {
            let text = systemSearch.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else {
                systemResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            systemResults = (try? await appState.backend.searchSystems(text)) ?? []
        }
    }
}
