import SwiftUI
import Observation

// MARK: - "Updating…" popup (whole app)

/// Everything the app is waiting on right now. Every page's data comes through BackendClient,
/// which reports each request here, so the popup covers the whole app without per-page work.
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    struct Activity: Identifiable {
        let id = UUID()
        let label: String
        let started = Date()
    }

    private(set) var activities: [Activity] = []
    /// Short messages from right-click actions ("Market opened in game ✓", or why it couldn't) – shown 4 s.
    private(set) var messages: [Activity] = []

    func flash(_ text: String) {
        let message = Activity(label: text)
        messages.append(message)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            self.messages.removeAll { $0.id == message.id }
        }
    }

    func start(_ label: String) -> UUID {
        let activity = Activity(label: label)
        activities.append(activity)
        return activity.id
    }

    func finish(_ id: UUID) {
        activities.removeAll { $0.id == id }
    }

    /// Labels of what's still running after `delay` seconds (quick loads never flash a popup), oldest first.
    func visibleLabels(at now: Date, delay: TimeInterval = 0.6) -> [String] {
        var seen: Set<String> = []
        return activities.filter { now.timeIntervalSince($0.started) >= delay }.compactMap { a in
            seen.insert(a.label).inserted ? a.label : nil
        }
    }

    /// Plain words for a request – nil for ones too small to mention (search suggestions, quick lookups).
    nonisolated static func label(method: String, path: String, query: [URLQueryItem]) -> String? {
        let quick = query.first { $0.name == "quick" }?.value == "true"
        switch path {
        case "haul/route": return quick ? "Planning the route" : "Checking kills and ganks along the route"
        case "haul/waypoints": return "Sending the route to the game"
        case "haul/plan": return "Working out the haul"
        case "haul/ships": return "Reading your ships"
        case "haul/optimise": return "Finding the best order for your stops"
        case "haul/here": return "Finding where you are"
        case "watch/summary": return quick ? "Updating the Watch List" : "Checking kills and ganks on your watched routes"
        case "watch/route", "watch/route/delete", "watch/route/rename", "ui/open", "ui/waypoint",
             "reference/blueprint-map": return nil
        case "market/item": return "Loading market data"
        case "market/groups", "market/types": return "Loading the market"
        case "market/my-orders": return "Updating your market orders"
        case "reference/build-vs-sell": return "Pricing builds"
        case "reference/blueprint-payback": return "Working out blueprint payback"
        case "build/copying": return "Reading copy contracts"
        case "build/plan": return "Planning the build"
        case "industry/calculate": return "Calculating the job"
        case "industry/products", "industry/my-products", "industry/products-in-group": return "Loading blueprints"
        case "industry/stock-locations": return "Reading your hangars"
        case "finances/summary", "dashboard/wallet": return "Updating finances"
        case "mining/ledger": return "Updating the mining ledger"
        case "reprocessing/summary", "reprocessing/ores": return "Working out reprocessing"
        case "reprocess-or-sell/summary": return "Checking what's worth reprocessing"
        case "reprocess-or-sell/item": return "Pricing at all five hubs"
        case "character/summary", "character": return "Updating your pilot"
        case "esi/skills", "esi/skillqueue", "sde/skills": return "Updating skills"
        case "esi/blueprints": return "Reading your blueprints"
        case "esi/industry/jobs", "history/jobs": return "Updating industry jobs"
        case "history/sync": return "Syncing history"
        case "history/track-record", "history/order-results", "history/net-worth": return "Reading your history"
        case "sde/update": return "Updating static data"
        // Typing suggestions, small lookups and settings – fast, not worth a popup.
        case "reference/suggest", "reprocess-or-sell/suggest", "market/search", "market/names", "haul/places", "industry/systems",
             "reference/materials", "health", "sde/status", "history/watchlist", "history/watch",
             "reference/blueprint-categories", "market/hubs", "esi/locations":
            return nil
        default: return method == "GET" ? "Updating" : "Saving"
        }
    }
}

/// The popup itself: bottom-right of the window, one line per thing being updated; gone when done.
struct ActivityPopup: View {
    private let center = ActivityCenter.shared

    var body: some View {
        // Only ticks while something is loading – when nothing is, there's no timer at all.
        VStack(alignment: .trailing, spacing: 8) {
            if !center.messages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(center.messages) { message in
                        Text(message.label).font(.callout)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .padding([.horizontal, .top], 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !center.activities.isEmpty {
                ticking
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.messages.count)
        .allowsHitTesting(false)
    }

    private var ticking: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let labels = center.visibleLabels(at: context.date)
            Group {
                if !labels.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(labels, id: \.self) { label in
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(label + "…").font(.callout)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: labels)
        }
        .padding(16)
        .allowsHitTesting(false)
    }
}
