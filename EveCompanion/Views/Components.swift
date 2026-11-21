import SwiftUI

/// Connection status: a dot + short line in the toolbar (`compact`), or the fuller pill.
struct ConnectionStatusView: View {
    @Environment(AppState.self) private var appState
    /// Toolbar version: dot + one short line, details on hover.
    var compact = false

    var body: some View {
        // Re-checked every 30 seconds so the downtime notice comes and goes on its own.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            pill
        }
    }

    /// EVE's daily downtime (11:00 UTC) – shown instead of "Connected" while it lasts.
    private var inDowntime: Bool { EveDowntime.isNow() }

    @ViewBuilder
    private var pill: some View {
        if compact {
            HStack(spacing: 6) {
                Circle()
                    .fill(inDowntime ? Color.orange : color)
                    .frame(width: 8, height: 8)
                Text(inDowntime ? "EVE downtime" : title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .help(compactHelp)
        } else {
            fullPill
        }
    }

    private var compactHelp: String {
        var text = inDowntime ? EveDowntime.message : helpText
        if let updated = appState.lastUpdated {
            text += "\nUpdated " + updated.formatted(.relative(presentation: .named))
        }
        return text
    }

    private var fullPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(inDowntime ? Color.orange : color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(inDowntime ? "EVE downtime – back soon" : title)
                    .font(.caption)
                if let updated = appState.lastUpdated {
                    Text("Updated \(updated, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .help(inDowntime ? EveDowntime.message : helpText)
    }

    private var color: Color {
        switch appState.connection {
        case .online: appState.isAuthenticated ? .green : .orange
        case .checking, .unknown: .secondary
        case .offline: .red
        }
    }

    private var title: String {
        switch appState.connection {
        case .unknown: "Not checked"
        case .checking: "Connecting…"
        case .offline: "Offline"
        case .online: appState.isAuthenticated ? "Connected" : "Not logged in"
        }
    }

    private var helpText: String {
        if case let .offline(message) = appState.connection { return message }
        return appState.authError ?? (appState.isAuthenticated ? "Logged in with EVE Online" : "Not logged in")
    }
}

/// Shows offline / login prompts until a character is available, then the content.
struct RequiresCharacter<Content: View>: View {
    @Environment(AppState.self) private var appState
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        switch appState.connection {
        case .unknown:
            connectingView

        case .checking where !appState.isAuthenticated:
            connectingView

        case let .offline(message):
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await appState.refreshAll() } }
                    .buttonStyle(.borderedProminent)
            }

        default:
            if appState.isAuthenticated {
                content()
            } else {
                ContentUnavailableView {
                    Label("Not Logged In", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Log in with EVE Online in your browser to authorise a character.")
                } actions: {
                    Button("Log In with EVE Online") { appState.openLogin() }
                        .buttonStyle(.borderedProminent)
                    if let error = appState.authError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

extension RequiresCharacter {
    fileprivate var connectingView: some View {
        ProgressView("Loading…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Placeholder for sections not built yet.
struct ComingSoonView: View {
    let item: SidebarItem
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(item.title, systemImage: item.systemImage)
        } description: {
            Text(detail)
            Text("In development").foregroundStyle(.secondary)
        }
    }
}

/// Five-segment skill level bar, like the in-game indicator.
struct SkillLevelIndicator: View {
    let level: Int
    var activeLevel: Int? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fill(for: index))
                    .frame(width: 9, height: 9)
            }
        }
        .accessibilityLabel("Level \(level)")
    }

    private func fill(for index: Int) -> Color {
        if index <= min(level, activeLevel ?? level) { return .accentColor }
        if index <= level { return .orange } // trained but not active (e.g. alpha clone)
        return Color.secondary.opacity(0.25)
    }
}

/// One look for every line chart in the app (user, 15 Nov 2026: half the default thickness).
enum ChartStyle {
    static let lineWidth: CGFloat = 1
    static var line: StrokeStyle { StrokeStyle(lineWidth: lineWidth) }
    /// Reference lines (averages, fair price): same thickness, dashed.
    static var referenceLine: StrokeStyle { StrokeStyle(lineWidth: lineWidth, dash: [4, 3]) }
}

/// Highlights the row you click in tables that don't otherwise use a selection –
/// just to make the row easier to follow across the columns. One per view;
/// each table gets its own key: `Table(rows, selection: highlight.row("ores"))`.
@Observable final class RowHighlights {
    private var picked: [String: AnyHashable] = [:]

    func row<ID: Hashable>(_ key: String) -> Binding<ID?> {
        Binding(
            get: { self.picked[key]?.base as? ID },
            set: { self.picked[key] = $0.map { AnyHashable($0) } }
        )
    }
}
