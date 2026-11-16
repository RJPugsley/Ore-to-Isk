import SwiftUI

struct IndustryJobsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(HistoryRange.key) private var rangeDays = HistoryRange.defaultDays
    @State private var completed: CompletedJobs?
    @State private var completedError: String?

    var body: some View {
        VSplitView {
            activeJobs
                .frame(minHeight: 140, maxHeight: .infinity)
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
                Table(completed.jobs) {
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
                    List(appState.industryJobs) { job in
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
