import SwiftUI

struct SkillQueueView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.skillQueue.isEmpty {
                ContentUnavailableView(
                    "Skill Queue Empty",
                    systemImage: "list.number",
                    description: Text("This character has nothing queued for training.")
                )
            } else {
                List(appState.skillQueue) { entry in
                    SkillQueueRow(
                        entry: entry,
                        name: appState.name(for: entry.skillId),
                        isTraining: entry.id == appState.skillQueue.first?.id
                    )
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard let end = appState.skillQueue.last?.finishDate else {
            return "\(appState.skillQueue.count) queued"
        }
        let formatted = end.formatted(.dateTime.day().month().year().hour().minute())
        return "\(appState.skillQueue.count) queued · ends \(formatted)"
    }
}

private struct SkillQueueRow: View {
    let entry: SkillQueueEntry
    let name: String
    let isTraining: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(entry.queuePosition + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).fontWeight(isTraining ? .semibold : .regular)
                    Text(entry.finishedLevel.roman).foregroundStyle(.secondary)
                    if isTraining {
                        Text("Training")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                if isTraining, let progress = entry.progress() {
                    ProgressView(value: progress)
                        .frame(maxWidth: 300)
                }
            }

            Spacer()

            SkillLevelIndicator(level: entry.finishedLevel)

            if let finish = entry.finishDate {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(finish, style: .relative)
                        .monospacedDigit()
                    Text(finish, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 140, alignment: .trailing)
            } else {
                Text("Paused")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 140, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }
}
