import SwiftUI

// MARK: - Models (/sde/skills)

struct SkillCatalogEntry: Decodable, Identifiable {
    let typeId: Int
    let name: String
    let groupName: String
    var id: Int { typeId }
}

struct SkillRow: Identifiable {
    let id: Int
    let name: String
    let trainedLevel: Int
    let activeLevel: Int
    let skillpoints: Int
    /// Highest level this skill reaches in your training queue, and when.
    let queuedLevel: Int?
    let queuedFinish: Date?
    var isTrained: Bool { skillpoints > 0 || trainedLevel > 0 }
}

struct SkillGroupRows: Identifiable {
    let name: String
    let rows: [SkillRow]
    let totalInGroup: Int
    var id: String { name }
    var trainedCount: Int { rows.filter(\.isTrained).count }
    var skillpoints: Int { rows.reduce(0) { $0 + $1.skillpoints } }
}

// MARK: - View

/// Your skills laid out like the game's Skill Catalogue: a grid of groups, then the chosen group's skills.
struct SkillsView: View {
    @Environment(AppState.self) private var appState
    @State private var catalog: [SkillCatalogEntry] = []
    @State private var searchText = ""
    @AppStorage("skills.selectedGroup") private var selectedGroup = "Production"

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    private var groups: [SkillGroupRows] {
        let mine = Dictionary((appState.skills?.skills ?? []).map { ($0.skillId, $0) }, uniquingKeysWith: { a, _ in a })
        var queued: [Int: (level: Int, finish: Date?)] = [:]
        for entry in appState.skillQueue where entry.finishedLevel >= (queued[entry.skillId]?.level ?? 0) {
            queued[entry.skillId] = (entry.finishedLevel, entry.finishDate)
        }

        var entries = catalog
        let known = Set(catalog.map(\.typeId))
        for id in mine.keys where !known.contains(id) {
            entries.append(SkillCatalogEntry(typeId: id, name: appState.name(for: id), groupName: "Other"))
        }

        let byGroup = Dictionary(grouping: entries, by: \.groupName)
        return byGroup.keys.sorted().map { name in
            let rows = (byGroup[name] ?? []).map { entry -> SkillRow in
                let skill = mine[entry.typeId]
                return SkillRow(
                    id: entry.typeId,
                    name: entry.name,
                    trainedLevel: skill?.trainedSkillLevel ?? 0,
                    activeLevel: skill?.activeSkillLevel ?? 0,
                    skillpoints: skill?.skillpointsInSkill ?? 0,
                    queuedLevel: queued[entry.typeId]?.level,
                    queuedFinish: queued[entry.typeId]?.finish
                )
            }
            .sorted { $0.name < $1.name }
            return SkillGroupRows(name: name, rows: rows, totalInGroup: rows.count)
        }
    }

    var body: some View {
        let groups = self.groups
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                trainingSummary

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 8) {
                    ForEach(groups) { group in
                        groupTile(group)
                    }
                }

                Divider()

                skillList(groups)
            }
            .padding(16)
        }
        .searchable(text: $searchText, prompt: "Search skills")
        .searchSuggestions {
            ForEach(localSuggestions(searchText, from: catalog.map(\.name)), id: \.self) { name in
                Text(name).searchCompletion(name)
            }
        }
        .task {
            if catalog.isEmpty {
                catalog = (try? await appState.backend.skillCatalog()) ?? []
            }
        }
    }

    // MARK: Training summary (replaces the old Skill Queue page)

    private var trainingSummary: some View {
        let queue = appState.skillQueue
        let current = queue.first
        let queueEnd = queue.compactMap(\.finishDate).max()

        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Training").font(.caption).foregroundStyle(.secondary)
                if let current {
                    HStack(spacing: 8) {
                        GameLevelBoxes(trained: current.finishedLevel - 1, queued: current.finishedLevel, started: true)
                        Text("\(appState.name(for: current.skillId)) \(current.finishedLevel.roman)")
                            .font(.headline)
                        Spacer()
                        if let finish = current.finishDate {
                            Text(finish, style: .relative)
                                .monospacedDigit()
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    ProgressView(value: current.progress() ?? 0)
                } else {
                    Text("Nothing training – your queue is empty")
                        .font(.headline)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                Text("Training Queue").font(.caption).foregroundStyle(.secondary)
                if let queueEnd {
                    Text(Self.queueLength(until: queueEnd))
                        .font(.title2).bold().monospacedDigit()
                    Text("\(queue.count) skills · ends \(queueEnd.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("–").font(.title2)
                }
            }

            if let skills = appState.skills {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Total Skill Points").font(.caption).foregroundStyle(.secondary)
                    Text(skills.totalSp.short)
                        .font(.title2).bold().monospacedDigit()
                    if let unallocated = skills.unallocatedSp, unallocated > 0 {
                        Text("\(unallocated.short) unallocated")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    /// "524d 22h 53m", like the game's Training Time.
    static func queueLength(until end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSinceNow))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }

    // MARK: Group tiles

    private func groupTile(_ group: SkillGroupRows) -> some View {
        let selected = query.isEmpty && group.name == selectedGroup
        let fraction = group.totalInGroup > 0 ? Double(group.trainedCount) / Double(group.totalInGroup) : 0
        return Button {
            selectedGroup = group.name
            searchText = ""
        } label: {
            HStack(spacing: 10) {
                Image(systemName: SkillGroupIcon.symbol(for: group.name))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(group.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(group.totalInGroup)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(alignment: .leading) {
                // Like the game: the bar behind the name shows how much of the group you've trained.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.quaternary.opacity(0.35))
                        Rectangle()
                            .fill(Color.accentColor.opacity(selected ? 0.45 : 0.22))
                            .frame(width: geo.size.width * fraction)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(group.trainedCount) of \(group.totalInGroup) trained · \(group.skillpoints.short) SP")
    }

    // MARK: Skills of the chosen group (or search results)

    @ViewBuilder
    private func skillList(_ groups: [SkillGroupRows]) -> some View {
        let rows: [SkillRow] = query.isEmpty
            ? (groups.first { $0.name == selectedGroup }?.rows ?? [])
            : groups.flatMap(\.rows).filter { $0.name.localizedCaseInsensitiveContains(query) }

        if rows.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            if query.isEmpty, let group = groups.first(where: { $0.name == selectedGroup }) {
                HStack {
                    Text(group.name).font(.headline)
                    Spacer()
                    Text("\(group.trainedCount) of \(group.totalInGroup) trained · \(group.skillpoints.short) SP")
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)],
                      alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    skillRow(row)
                }
            }
        }
    }

    private func skillRow(_ row: SkillRow) -> some View {
        HStack(spacing: 10) {
            GameLevelBoxes(trained: row.trainedLevel, queued: row.queuedLevel ?? 0, started: row.isTrained)
            Text(row.name)
                .lineLimit(1)
                .foregroundStyle(row.isTrained ? Color.primary : Color.secondary)
            Spacer(minLength: 6)
            Group {
                if let finish = row.queuedFinish, let level = row.queuedLevel {
                    Text(finish, style: .relative)
                        .foregroundStyle(Color.accentColor)
                        .help("Training to \(level.roman) in your queue")
                } else if row.trainedLevel == 5 {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                } else if !row.isTrained {
                    Text("Not trained").foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .monospacedDigit()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
        .help("\(row.skillpoints.short) skill points")
        .contextMenu {
            Section(row.name) {
                Button("Show Info in Game") { appState.showInGame(row.id, market: false, name: row.name) }
                Button("Copy Name") { copyToClipboard(row.name) }
                if let url = URL(string: "https://everef.net/types/\(row.id)") {
                    Link("Open on EVE Ref", destination: url)
                }
            }
        }
    }
}

/// The game's five level boxes: filled = trained, accent = in your queue, outline = not trained.
struct GameLevelBoxes: View {
    let trained: Int
    let queued: Int
    let started: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { level in
                Group {
                    if level <= trained {
                        RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.85))
                    } else if level <= queued {
                        RoundedRectangle(cornerRadius: 1).fill(Color.accentColor)
                    } else {
                        RoundedRectangle(cornerRadius: 1)
                            .strokeBorder(Color.secondary.opacity(started ? 0.6 : 0.35),
                                          style: StrokeStyle(lineWidth: 1, dash: started ? [] : [2, 2]))
                    }
                }
                .frame(width: 9, height: 9)
            }
        }
    }
}

/// SF Symbol for each skill group, standing in for the game's icons.
enum SkillGroupIcon {
    static func symbol(for group: String) -> String {
        switch group {
        case "Armor": "shield.lefthalf.filled"
        case "Corporation Management": "building.2"
        case "Drones": "ant"
        case "Electronic Systems": "cpu"
        case "Engineering": "bolt"
        case "Fleet Support": "person.3"
        case "Gunnery": "scope"
        case "Missiles": "paperplane"
        case "Navigation": "location.north.line"
        case "Neural Enhancement": "brain.head.profile"
        case "Planet Management": "globe.europe.africa"
        case "Production": "hammer"
        case "Resource Processing": "arrow.3.trianglepath"
        case "Rigging": "wrench.and.screwdriver"
        case "Scanning": "dot.radiowaves.left.and.right"
        case "Science": "flask"
        case "Sequencing": "arrow.triangle.branch"
        case "Shields": "shield"
        case "Social": "person.2"
        case "Spaceship Command": "airplane"
        case "Structure Management": "building.columns"
        case "Subsystems": "square.stack.3d.up"
        case "Targeting": "target"
        case "Trade": "chart.line.uptrend.xyaxis"
        default: "questionmark.circle"
        }
    }
}
