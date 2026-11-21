import SwiftUI

struct IndustryJobsView: View {
    @State private var highlight = RowHighlights()
    @Environment(AppState.self) private var appState
    @AppStorage(HistoryRange.key) private var rangeDays = HistoryRange.defaultDays
    @State private var completed: CompletedJobs?
    @State private var completedError: String?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                slotStrip
                activeJobs
            }
            .frame(minHeight: 220, maxHeight: .infinity)
            completedJobs
                .frame(minHeight: 180, maxHeight: .infinity)
        }
        .navigationSubtitle(subtitle)
        .task {
            if appState.industryJobs.isEmpty { await appState.loadIndustry() }
        }
        .task(id: rangeDays) {
            do {
                completed = try await appState.backend.completedJobs()
                completedError = nil
            } catch {
                completedError = error.localizedDescription
            }
        }
    }

    // MARK: Job slots

    /// Skill type IDs (CCP static data).
    private enum SlotSkill {
        static let massProduction = 3387
        static let advancedMassProduction = 24625
        static let laboratoryOperation = 3406
        static let advancedLaboratoryOperation = 24624
        static let massReactions = 45748
        static let advancedMassReactions = 45749
    }

    private struct SlotGroup: Identifiable {
        let id: String
        let title: String
        let icon: String
        let used: Int
        let ready: Int
        /// nil = skills not loaded yet.
        let max: Int?
        let help: String
    }

    /// Active skill level, 0 if untrained; nil while skills aren't loaded.
    private func level(_ skillID: Int) -> Int? {
        guard let skills = appState.skills else { return nil }
        return skills.skills.first(where: { $0.skillId == skillID })?.activeSkillLevel ?? 0
    }

    private func slotGroup(id: String, title: String, icon: String, activities: Set<IndustryActivity>,
                           skill1: Int, name1: String, skill2: Int, name2: String) -> SlotGroup {
        // Finished jobs keep their slot until delivered, so count everything not delivered / cancelled.
        let jobs = appState.industryJobs.filter {
            activities.contains($0.activity) && $0.status != "delivered" && $0.status != "cancelled"
        }
        let ready = jobs.filter(\.isReady).count
        var maxSlots: Int?
        var help = "Slots = 1 + \(name1) + \(name2)."
        if let l1 = level(skill1), let l2 = level(skill2) {
            maxSlots = 1 + l1 + l2
            help = "Slots = 1 + \(name1) (\(l1)) + \(name2) (\(l2))."
        }
        help += "\nFinished jobs still use a slot until you deliver them."
        return SlotGroup(id: id, title: title, icon: icon, used: jobs.count, ready: ready, max: maxSlots, help: help)
    }

    private var slotGroups: [SlotGroup] {
        var groups = [
            slotGroup(id: "manufacturing", title: "Manufacturing", icon: "hammer",
                      activities: [.manufacturing],
                      skill1: SlotSkill.massProduction, name1: "Mass Production",
                      skill2: SlotSkill.advancedMassProduction, name2: "Advanced Mass Production"),
            slotGroup(id: "science", title: "Science", icon: "flask.fill",
                      activities: [.researchTE, .researchME, .copying, .invention, .reverseEngineering],
                      skill1: SlotSkill.laboratoryOperation, name1: "Laboratory Operation",
                      skill2: SlotSkill.advancedLaboratoryOperation, name2: "Advanced Laboratory Operation"),
        ]
        let reactions = slotGroup(id: "reactions", title: "Reactions", icon: "flask",
                                  activities: [.reactions, .reactions2],
                                  skill1: SlotSkill.massReactions, name1: "Mass Reactions",
                                  skill2: SlotSkill.advancedMassReactions, name2: "Advanced Mass Reactions")
        // Only shown once you react (or have the skill) – keeps the strip to the two you use.
        if reactions.used > 0 || (level(SlotSkill.massReactions) ?? 0) > 0 {
            groups.append(reactions)
        }
        return groups
    }

    private var slotStrip: some View {
        HStack(spacing: 12) {
            ForEach(slotGroups) { group in
                SlotTile(group: group)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private struct SlotTile: View {
        let group: SlotGroup

        var body: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label(group.title, systemImage: group.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(valueText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(valueColor)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let maxSlots = group.max, maxSlots > 0 {
                        ProgressView(value: Double(min(group.used, maxSlots)), total: Double(maxSlots))
                            .tint(valueColor == .primary ? .accentColor : valueColor)
                    }
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help(group.help)
        }

        private var free: Int? { group.max.map { Swift.max($0 - group.used, 0) } }

        private var valueText: String {
            guard let maxSlots = group.max else { return "\(group.used) running" }
            return "\(group.used) of \(maxSlots) in use"
        }

        private var valueColor: Color {
            guard let free else { return .primary }
            return free == 0 ? .orange : .green
        }

        private var detailText: String {
            var parts: [String] = []
            if let free {
                parts.append(free == 0 ? "All slots in use" : "\(free) more you can start")
            } else {
                parts.append("Loading skills…")
            }
            if group.ready > 0 { parts.append("\(group.ready) ready to deliver") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Completed (from your history)

    @ViewBuilder
    private var completedJobs: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Completed · \(HistoryRange.label(rangeDays))").font(.headline)
                Spacer()
                if let months = completed?.monthly, let latest = months.last {
                    Text("\(latest.month): \(latest.runs.short) runs built in \(latest.jobs) jobs · \(latest.cost.iskShort) fees")
                        .foregroundStyle(.secondary)
                        .help(months.reversed().map { "\($0.month): \($0.runs) runs, \($0.jobs) jobs, \($0.cost.iskShort)" }.joined(separator: "\n"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if let completed {
                Table(completed.jobs, selection: highlight.row("t48")) {
                    TableColumn("Finished") { job in
                        Text(job.endDate.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                    }
                    .width(min: 110, ideal: 140)
                    TableColumn("Item") { job in
                        HStack(spacing: 6) {
                            AsyncImage(url: PublicESIClient.typeIconURL(typeID: job.typeId, size: 32)) { image in
                                image.resizable()
                            } placeholder: { Color.clear }
                            .frame(width: 18, height: 18)
                            Text(job.name)
                        }
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn("Activity") { job in
                        Text((IndustryActivity(rawValue: job.activityId) ?? .unknown).title).foregroundStyle(.secondary)
                    }
                    TableColumn("Runs") { job in
                        Text(job.runs.short).monospacedDigit()
                    }
                    .width(min: 40, ideal: 60)
                    TableColumn("Fee") { job in
                        Text(job.cost.iskShort).monospacedDigit()
                    }
                    TableColumn("Where") { job in
                        Text(job.location ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }
                    .width(min: 120, ideal: 220)
                    TableColumn("Status") { job in
                        Text(job.status.capitalized)
                            .foregroundStyle(job.status == "cancelled" ? Color.orange : Color.secondary)
                    }
                    .width(min: 60, ideal: 80)
                }
                .contextMenu(forSelectionType: CompletedJob.ID.self) { ids in
                    if let id = ids.first, let job = completed.jobs.first(where: { $0.id == id }) {
                        ItemMenu(typeID: job.typeId, name: job.name)
                    }
                }
                .overlay {
                    if completed.jobs.isEmpty {
                        ContentUnavailableView("No Completed Jobs Yet", systemImage: "clock",
                                               description: Text("Finished jobs are saved each time you open the app."))
                    }
                }
            } else if let completedError {
                Text(completedError).foregroundStyle(.secondary).padding(16)
                Spacer()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Active

    @ViewBuilder
    private var activeJobs: some View {
        Group {
            if appState.industryJobs.isEmpty {
                if appState.isLoadingIndustry {
                    ProgressView("Loading industry jobs…")
                } else if let error = appState.industryError {
                    ContentUnavailableView {
                        Label("Couldn't Load Jobs", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await appState.loadIndustry() } }
                    }
                } else {
                    ContentUnavailableView("No Active Jobs", systemImage: "gearshape.2",
                                           description: Text("Nothing is running in any industry slot."))
                }
            } else {
                // Re-render every 30 s so progress bars move.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    List(appState.industryJobs, selection: highlight.row("active") as Binding<IndustryJob.ID?>) { job in
                        IndustryJobRow(job: job, now: context.date)
                            .contextMenu {
                                if let product = job.productTypeId {
                                    ItemMenu(typeID: product, name: appState.name(for: product))
                                }
                                if let place = appState.location(for: job.facilityId) {
                                    PlaceMenu(locationID: job.facilityId, name: place.station)
                                }
                            }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
        }
    }

    private var subtitle: String {
        let jobs = appState.industryJobs
        guard !jobs.isEmpty else { return "" }
        let ready = jobs.filter(\.isReady).count
        return ready > 0 ? "\(jobs.count) jobs · \(ready) ready to deliver" : "\(jobs.count) jobs"
    }
}

private struct IndustryJobRow: View {
    @Environment(AppState.self) private var appState
    let job: IndustryJob
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: PublicESIClient.typeIconURL(typeID: job.productTypeId ?? job.blueprintTypeId, size: 64)) { image in
                image.resizable()
            } placeholder: {
                Image(systemName: job.activity.systemImage).foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    Text("× \(job.runs)").foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Label(job.activity.title, systemImage: job.activity.systemImage)
                    Text("·")
                    Text(appState.location(for: job.facilityId)?.station ?? "Facility \(job.facilityId)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ProgressView(value: job.progress(at: now))
                    .frame(maxWidth: 320)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if job.isReady {
                    Text("Ready").fontWeight(.semibold).foregroundStyle(.green)
                } else {
                    Text(job.endDate, style: .relative).monospacedDigit()
                }
                Text(job.endDate, format: .dateTime.day().month().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let cost = job.cost, cost > 0 {
                    Text(cost.iskShort)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 140, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if let product = job.productTypeId, job.activity == .manufacturing || job.activity == .reactions || job.activity == .reactions2 {
            return appState.name(for: product)
        }
        return appState.name(for: job.blueprintTypeId)
    }
}
