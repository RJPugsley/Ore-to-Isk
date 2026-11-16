import AppKit
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case skills
    case finances
    case marketOrders
    case skillQueue
    case manufacturing
    case reprocessing
    case oreDatabase
    case buildVsSell
    case blueprints
    case industryJobs
    case miningLedger
    case buildPlanner
    case blueprintPayback
    case blueprintCopying
    case market
    case haulRoute
    case haulWatch
    case haulPlanner

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .skills: "Skills"
        case .finances: "Finances"
        case .marketOrders: "Market Orders"
        case .skillQueue: "Skill Queue"
        case .manufacturing: "Manufacturing"
        case .reprocessing: "Reprocessing"
        case .oreDatabase: "Ore Database"
        case .buildVsSell: "Build vs Sell"
        case .blueprints: "Blueprints"
        case .industryJobs: "Industry Jobs"
        case .miningLedger: "Mining Ledger"
        case .buildPlanner: "Build Planner"
        case .blueprintPayback: "Blueprint Payback"
        case .blueprintCopying: "Blueprint Copying"
        case .market: "Market"
        case .haulRoute: "Route"
        case .haulWatch: "Watch List"
        case .haulPlanner: "Haul Planner"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "person.crop.circle"
        case .skills: "book.closed"
        case .finances: "banknote"
        case .marketOrders: "cart"
        case .skillQueue: "list.number"
        case .manufacturing: "hammer"
        case .reprocessing: "arrow.3.trianglepath"
        case .oreDatabase: "cube.transparent"
        case .buildVsSell: "scalemass"
        case .blueprints: "doc.text"
        case .industryJobs: "gearshape.2"
        case .miningLedger: "chart.line.uptrend.xyaxis"
        case .buildPlanner: "hammer.circle"
        case .blueprintPayback: "creditcard"
        case .blueprintCopying: "doc.on.doc"
        case .market: "chart.bar.doc.horizontal"
        case .haulRoute: "point.topleft.down.to.point.bottomright.curvepath"
        case .haulWatch: "binoculars"
        case .haulPlanner: "shippingbox"
        }
    }

    /// Pages whose figures depend on the History time frame – they get the picker in the toolbar.
    var usesHistory: Bool {
        switch self {
        case .dashboard, .finances, .marketOrders, .manufacturing, .buildVsSell,
             .industryJobs, .miningLedger, .blueprintCopying: true
        default: false
        }
    }

    /// Pages still being built – shown with an "In development" note.
    var inDevelopment: String? {
        switch self {
        default:
            nil
        }
    }
}

/// Workflow tabs across the top. A page can sit in more than one tab (same page, same settings).
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case pilot, mine, build, sell, haul

    var id: Self { self }

    var title: String {
        switch self {
        case .pilot: "Pilot"
        case .mine: "Mine"
        case .build: "Build"
        case .sell: "Sell"
        case .haul: "Haul"
        }
    }

    var systemImage: String {
        switch self {
        case .pilot: "person.crop.circle"
        case .mine: "cube.transparent"
        case .build: "hammer"
        case .sell: "cart"
        case .haul: "shippingbox"
        }
    }

    var pages: [SidebarItem] {
        switch self {
        case .pilot: [.dashboard, .skills, .finances]
        case .mine: [.miningLedger, .buildPlanner, .reprocessing, .oreDatabase]
        case .build: [.manufacturing, .blueprints, .blueprintCopying, .industryJobs, .buildVsSell, .blueprintPayback, .buildPlanner, .reprocessing]
        case .sell: [.market, .marketOrders, .buildVsSell, .blueprintCopying, .finances]
        case .haul: [.haulPlanner, .haulRoute, .haulWatch]
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState

    /// Always opens on the Pilot tab (character summary).
    @State private var tab: AppTab = .pilot
    @State private var selection: SidebarItem? = .dashboard
    /// The page you last had open in each tab, so switching back returns to it.
    @State private var lastPage: [AppTab: SidebarItem] = [:]
    /// Which tab's hover menu is open (one at a time).
    @State private var tabHover = TabHoverModel()
    /// First run: the welcome / setup sheet (Views/WelcomeView.swift).
    @State private var showWelcome = !FirstRun.isDone

    /// The character summary page is named after your character.
    private func title(for item: SidebarItem) -> String {
        item == .dashboard ? (appState.character?.name ?? "Character") : item.title
    }

    var body: some View {
        // No sidebar: the tabs (and their hover menus) pick the page.
        detailView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(selection.map(title(for:)) ?? AppInfo.name)
            // "Updating…" popup for anything the app is waiting on – closes by itself when done.
            .overlay(alignment: .bottomTrailing) { ActivityPopup() }
            .sheet(isPresented: $showWelcome) {
                WelcomeView()
                    .environment(appState)
            }
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Tabs; hover one for a menu of its pages (click the tab itself to switch as before).
                HStack(spacing: 6) {
                    ForEach(AppTab.allCases) { item in
                        TabMenuButton(tab: item, selected: tab == item, hover: tabHover, pageTitle: title(for:)) {
                            tab = item
                        } openPage: { page in
                            tab = item
                            selection = page
                        }
                    }
                }
                .padding(2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                // No tooltip here – it would sit on top of the hover menus.
            }
            ToolbarItem(placement: .navigation) {
                ConnectionStatusView(compact: true)
            }
            ToolbarItem(placement: .primaryAction) {
                // Only on pages that show results over a period.
                if selection?.usesHistory == true {
                    HistoryRangePicker().fixedSize()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if appState.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await appState.refreshAll() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh character data (⌘R)")
                }
            }
        }
        .background {
            // ⌘1 – ⌘5 switch tabs.
            ForEach(AppTab.allCases) { item in
                let number = (AppTab.allCases.firstIndex(of: item) ?? 0) + 1
                Button("") { tab = item }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: selection) { _, newValue in
            HelpCenter.shared.currentPage = newValue     // for Help → Help for This Page
            if let newValue, tab.pages.contains(newValue) { lastPage[tab] = newValue }
        }
        .onChange(of: appState.goToPage) { _, page in
            // A page asked to open another (e.g. Watch List → Route).
            guard let page else { return }
            if !tab.pages.contains(page), let home = AppTab.allCases.first(where: { $0.pages.contains(page) }) { tab = home }
            selection = page
            appState.goToPage = nil
        }
        .onChange(of: tab) { _, newTab in
            // Keep the current page if it's in the new tab too, else go back to that tab's last page.
            if let current = selection, newTab.pages.contains(current) { return }
            selection = lastPage[newTab] ?? newTab.pages.first
        }
        .task {
            HelpCenter.shared.currentPage = selection
            await appState.startup()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Pick up a fresh login when the user comes back from the browser.
            if !appState.isAuthenticated {
                Task { await appState.refreshAll() }
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .dashboard, .none:
            RequiresCharacter { DashboardView() }
        case .skills:
            RequiresCharacter { SkillsView() }
        case .finances:
            RequiresCharacter { FinancesView() }
        case .marketOrders:
            RequiresCharacter { MarketOrdersView() }
        case .skillQueue:
            RequiresCharacter { SkillQueueView() }
        case .manufacturing:
            RequiresCharacter { ManufacturingView() }
        case .reprocessing:
            RequiresCharacter { ReprocessingView() }
        case .oreDatabase:
            RequiresCharacter { OreDatabaseView() }
        case .buildVsSell:
            RequiresCharacter { BuildVsSellView() }
        case .blueprints:
            RequiresCharacter { BlueprintsView() }
        case .industryJobs:
            RequiresCharacter { IndustryJobsView() }
        case .miningLedger:
            RequiresCharacter { MiningLedgerView() }
        case .buildPlanner:
            RequiresCharacter { BuildPlannerView() }
        case .blueprintPayback:
            RequiresCharacter { BlueprintPaybackView() }
        case .blueprintCopying:
            RequiresCharacter { BlueprintCopyingView() }
        case .market:
            MarketView()
        case .haulPlanner:
            RequiresCharacter { HaulPlannerView() }
        case .haulRoute:
            RouteView()
        case .haulWatch:
            RequiresCharacter { WatchListView() }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .frame(width: 1000, height: 650)
}


// MARK: - Tab with a hover menu of its pages

/// Which tab's menu is open. Shared by all tabs so only one menu shows at a time,
/// and moving onto another tab switches the menu straight away.
@MainActor @Observable
final class TabHoverModel {
    var open: AppTab?
    private var overTab: AppTab?
    private var overMenu: AppTab?

    func tab(_ tab: AppTab, inside: Bool) {
        if inside {
            overTab = tab
            if open != nil {
                open = tab                       // a menu is already showing → switch at once
            } else {
                Task {
                    try? await Task.sleep(for: .milliseconds(150))   // passing over doesn't pop menus
                    if overTab == tab { open = tab }
                }
            }
        } else {
            if overTab == tab { overTab = nil }
            closeSoon()
        }
    }

    func menu(_ tab: AppTab, inside: Bool) {
        if inside { overMenu = tab } else {
            if overMenu == tab { overMenu = nil }
            closeSoon()
        }
    }

    func close() { open = nil; overMenu = nil }

    private func closeSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            if overTab == nil && overMenu == nil { open = nil }
            // Pointer moved to a different tab than the open menu → follow it.
            else if let over = overTab, overMenu == nil, open != over { open = over }
        }
    }
}

/// One tab in the top bar: click to switch tab; hover to drop down a list of its pages.
struct TabMenuButton: View {
    let tab: AppTab
    let selected: Bool
    let hover: TabHoverModel
    let pageTitle: (SidebarItem) -> String
    let selectTab: () -> Void
    let openPage: (SidebarItem) -> Void

    @State private var overButton = false

    var body: some View {
        Button(action: selectTab) {
            Text(tab.title)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .background(selected ? Color.secondary.opacity(0.25) : (overButton ? Color.secondary.opacity(0.12) : Color.clear),
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            overButton = inside
            hover.tab(tab, inside: inside)
        }
        .popover(isPresented: Binding(get: { hover.open == tab },
                                      set: { if !$0, hover.open == tab { hover.close() } }),
                 arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(tab.title).font(.caption.weight(.semibold))
                    Spacer()
                    Text("⌘\((AppTab.allCases.firstIndex(of: tab) ?? 0) + 1)").font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                ForEach(tab.pages) { page in
                    PageMenuRow(title: pageTitle(page), systemImage: page.systemImage) {
                        hover.close()
                        openPage(page)
                    }
                }
            }
            .padding(6)
            .frame(minWidth: 200, alignment: .leading)
            .onHover { inside in hover.menu(tab, inside: inside) }
        }
    }
}

private struct PageMenuRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(hovering ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
