import AppKit
import SwiftUI

struct BlueprintRow: Identifiable {
    let id: Int
    let typeId: Int
    let name: String
    let isCopy: Bool
    let me: Int
    let te: Int
    /// Int.max for originals so they sort after copies with finite runs.
    let runs: Int
    let quantity: Int
    let station: String
    let container: String
    let jobStatus: String

    var kind: String { isCopy ? "Copy" : "Original" }
    var runsLabel: String { runs == Int.max ? "∞" : runs.short }
}

struct BlueprintsView: View {
    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case originals = "Originals"
        case copies = "Copies"
        var id: Self { self }
    }

    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var kindFilter: KindFilter = .all
    @State private var stationFilter = ""          // "" = all locations
    @State private var sortOrder = [KeyPathComparator(\BlueprintRow.name)]
    @State private var selection = Set<BlueprintRow.ID>()
    /// Base materials (ME 0, one run) per blueprint type – for the right-click menu.
    @State private var baseMaterials: [Int: [MaterialNeed]] = [:]

    private var allRows: [BlueprintRow] {
        let jobs = appState.jobsByBlueprint
        return appState.blueprints.map { bp in
            let location = appState.location(for: bp.locationId)
            let job = jobs[bp.itemId]
            return BlueprintRow(
                id: bp.itemId,
                typeId: bp.typeId,
                name: appState.name(for: bp.typeId),
                isCopy: bp.isCopy,
                me: bp.materialEfficiency,
                te: bp.timeEfficiency,
                runs: bp.runs < 0 ? Int.max : bp.runs,
                quantity: bp.stackSize,
                station: location?.station ?? "Location \(bp.locationId)",
                container: location?.container ?? "",
                jobStatus: job.map { $0.isReady ? "\($0.activity.title) – ready" : $0.activity.title } ?? ""
            )
        }
    }

    private var stations: [String] {
        Array(Set(allRows.map(\.station))).sorted()
    }

    private var rows: [BlueprintRow] {
        allRows
            .filter { row in
                switch kindFilter {
                case .all: return true
                case .originals: return !row.isCopy
                case .copies: return row.isCopy
                }
            }
            .filter { stationFilter.isEmpty || $0.station == stationFilter }
            .filter { searchText.isEmpty
                || $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.container.localizedCaseInsensitiveContains(searchText) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if appState.blueprints.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Picker("Kind", selection: $kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Show originals, copies or both")

                Picker("Location", selection: $stationFilter) {
                    Text("All Locations").tag("")
                    Divider()
                    ForEach(stations, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 260)
                .help("Filter by station or structure")
            }
        }
        .searchable(text: $searchText, prompt: "Search blueprints or containers")
        .searchSuggestions {
            ForEach(localSuggestions(searchText, from: allRows.map(\.name) + allRows.map(\.container)), id: \.self) { name in
                Text(name).searchCompletion(name)
            }
        }
        .task {
            if appState.blueprints.isEmpty { await appState.loadIndustry() }
        }
        .task(id: Set(allRows.map(\.typeId))) {
            baseMaterials = await appState.backend.baseMaterials(Array(Set(allRows.map(\.typeId))))
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Blueprint", value: \.name) { row in
                HStack(spacing: 8) {
                    AsyncImage(url: PublicESIClient.blueprintIconURL(typeID: row.typeId, isCopy: row.isCopy, size: 32)) { image in
                        image.resizable()
                    } placeholder: {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                    }
                    .frame(width: 22, height: 22)
                    Text(row.name)
                }
            }
            .width(min: 220, ideal: 300)

            TableColumn("Kind", value: \.kind) { row in
                Text(row.kind).foregroundStyle(row.isCopy ? .secondary : .primary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("ME", value: \.me) { row in
                Text("\(row.me)").monospacedDigit()
            }
            .width(min: 30, ideal: 36)

            TableColumn("TE", value: \.te) { row in
                Text("\(row.te)").monospacedDigit()
            }
            .width(min: 30, ideal: 36)

            TableColumn("Runs", value: \.runs) { row in
                Text(row.runsLabel).monospacedDigit()
            }
            .width(min: 40, ideal: 50)

            TableColumn("Qty", value: \.quantity) { row in
                Text(row.quantity.short).monospacedDigit()
            }
            .width(min: 30, ideal: 40)

            TableColumn("Location", value: \.station)
                .width(min: 150, ideal: 260)

            TableColumn("Container", value: \.container)
                .width(min: 80, ideal: 140)

            TableColumn("In Use", value: \.jobStatus) { row in
                if !row.jobStatus.isEmpty {
                    Label(row.jobStatus, systemImage: "gearshape.2")
                        .foregroundStyle(.tint)
                }
            }
            .width(min: 80, ideal: 130)
        }
        .contextMenu(forSelectionType: BlueprintRow.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let row = allRows.first(where: { $0.id == id }) {
                if let product = appState.product(ofBlueprint: row.typeId) {
                    ItemMenu(typeID: product, name: row.name.replacingOccurrences(of: " Blueprint", with: ""))
                }
                if !row.isCopy {
                    Button("Blueprint Copying") { appState.goToPage = .blueprintCopying }
                }
                MaterialsMenuContent(title: "Materials – 1 run, ME \(row.me)",
                                     materials: materialsAtME(baseMaterials[row.typeId] ?? [], me: row.me))
                Divider()
            }
            Button("Copy Name") { copyNames(for: ids) }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView.search
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if appState.isLoadingIndustry {
            ProgressView("Loading blueprints…")
        } else if let error = appState.industryError {
            ContentUnavailableView {
                Label("Couldn't Load Blueprints", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await appState.loadIndustry() } }
            }
        } else {
            ContentUnavailableView("No Blueprints", systemImage: "doc.text",
                                   description: Text("This character doesn't own any blueprints."))
        }
    }

    private var subtitle: String {
        let all = appState.blueprints
        guard !all.isEmpty else { return "" }
        let copies = all.filter(\.isCopy).count
        return "\(rows.count) shown · \(all.count - copies) originals · \(copies) copies"
    }

    private func copyNames(for ids: Set<BlueprintRow.ID>) {
        let text = allRows.filter { ids.contains($0.id) }.map(\.name).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
