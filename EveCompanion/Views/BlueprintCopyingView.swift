import SwiftUI

// MARK: - Models (/build/copying)

struct CopyingResult: Decodable {
    let hub: String
    let regionId: Int
    let regionName: String
    let copyIndex: Double
    let feeRate: Double
    let scienceLevel: Int
    let advancedIndustryLevel: Int
    let labSlots: Int
    let copyOffersInRegion: Int
    let ownedOriginals: Int?
    let salesWindowDays: Int?
    /// When the app started watching copy contracts in this region (epoch seconds).
    let trackingSince: Double?
    let items: [CopyingItem]

    var trackingText: String {
        guard let trackingSince else { return "Sales tracking starts with this scan." }
        let since = Date(timeIntervalSince1970: trackingSince)
        return "Sales tracked since \(since.formatted(date: .abbreviated, time: .shortened)) (only while the app is open)."
    }
}

struct CopyOffer: Decodable {
    let contractId: Int
    let price: Double
    let runs: Int
    let me: Int
    let te: Int
    let pricePerRun: Double
}

struct CopyingItem: Decodable, Identifiable {
    let blueprintTypeId: Int
    let productTypeId: Int?
    let name: String
    let group: String?
    let owned: Bool?
    let me: Int
    let te: Int
    let maxRuns: Int
    let runsPerCopy: Int
    let copies: Int
    let copySecondsPerRun: Double
    let buildSecondsPerRun: Double
    let feePerRun: Double
    let offers: Int
    /// Copy contracts that vanished before expiry within the History range – probably bought.
    let probablySold: Int?
    let soldMedianPerRun: Double?
    let similarOffers: Int
    let typicalPerRun: Double?
    let lowestPerRun: Double?
    let cheapestOffer: CopyOffer?
    let marginPerRun: Double?
    let iskPerLabHour: Double?
    let verdict: String
    let totalSeconds: Double
    let totalFee: Double
    let totalValue: Double?
    let totalMargin: Double?

    var id: Int { blueprintTypeId }

    // Sort keys – nothing to compare → bottom.
    var typicalSort: Double { typicalPerRun ?? -1 }
    var marginSort: Double { marginPerRun ?? -.greatestFiniteMagnitude }
    var perHourSort: Double { iskPerLabHour ?? -.greatestFiniteMagnitude }
    var offersSort: Int { offers }
    var isOwned: Bool { owned ?? false }
    var ownedSort: Int { isOwned ? 1 : 0 }

    var blueprintLabel: String { isOwned ? "BPO · ME \(me)" : "Not owned" }

    /// Read like Build vs Sell's Verdict: the answer and the number that matters.
    var verdictText: String {
        switch verdict {
        case "copy": return "Copy +\((iskPerLabHour ?? 0).short)/h"
        case "not_worth": return "Skip \((marginPerRun ?? 0).short)/run"
        case "thin": return "Too few (\(offers))"
        default: return "No market"
        }
    }

    var soldCount: Int { probablySold ?? 0 }

    var contractsText: String {
        let listed = offers == 0 ? "None listed" : "\(offers) listed"
        return soldCount > 0 ? "\(listed) · ~\(soldCount) sold" : listed
    }

    var verdictColor: Color {
        switch verdict {
        case "copy": return .green
        case "not_worth": return .red
        default: return .secondary
        }
    }

    var verdictHelp: String {
        switch verdict {
        case "copy":
            return "Copies of this sell on contracts for more than they cost to make."
        case "not_worth":
            return "Copies sell on contracts for less than the copy fee – not worth the lab time."
        case "thin":
            return "Only \(offers) copy offer(s) on contracts in the region – too few to trust a price."
        default:
            return "Nobody is selling copies of this on contracts in the region, so there's no price to go by. That can mean no demand – or an open market."
        }
    }

    var priceHelp: String {
        var text = "\(offers) contract(s) selling a single copy in the region"
        if similarOffers != offers { text += ", \(similarOffers) at ME \(me) or better" }
        text += ".\nTypical = median per run of " + (soldCount >= 3 ? "what probably sold." : (similarOffers >= 3 && similarOffers != offers ? "copies listed at ME \(me) or better." : "the asking prices."))
        if soldCount > 0 {
            text += "\n~\(soldCount) probably sold (\(HistoryRange.label(HistoryRange.days)))"
            if let sold = soldMedianPerRun { text += " at a typical \(sold.iskShort) a run" }
            text += " (contracts that vanished before they expired – could also be cancellations)."
        }
        if let lowest = lowestPerRun { text += "\nCheapest listed: \(lowest.iskShort) a run." }
        if let cheapest = cheapestOffer {
            text += "\nCheapest: \(cheapest.runs) runs ME \(cheapest.me) TE \(cheapest.te) for \(cheapest.price.iskShort) (\(cheapest.pricePerRun.iskShort) a run)."
        }
        return text
    }

    var batchHelp: String {
        var text = "\(copies) cop\(copies == 1 ? "y" : "ies") × \(runsPerCopy) runs (max \(maxRuns) a copy)."
        text += "\nLab time \(totalSeconds.durationLabel) · fees \(totalFee.iskShort)"
        if let value = totalValue { text += "\nWorth about \(value.iskShort) on contracts" }
        if let margin = totalMargin { text += " → \(margin.iskShort) after fees." }
        return text
    }
}

// MARK: - View

/// Build: is copying a blueprint original to sell on contracts worth it?
struct BlueprintCopyingView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(BuildSettingsKey.systemId) private var systemId = BuildSettingsKey.defaultSystemId
    @AppStorage(BuildSettingsKey.structure) private var structure = StructureKind.npc.rawValue
    @AppStorage(BuildSettingsKey.facilityTax) private var facilityTax = 0.25

    @AppStorage("copying.hub") private var hub = BuildSettingsKey.defaultHub
    @AppStorage("copying.runsPerCopy") private var runsPerCopy = 0   // 0 = the most a copy can have
    @AppStorage("copying.copies") private var copies = 1
    @AppStorage(HistoryRange.key) private var rangeDays = HistoryRange.defaultDays
    @AppStorage("copying.category") private var category = "Ship"
    @AppStorage("copying.group") private var group = "Frigate"
    @AppStorage("copying.ownedOnly") private var ownedOnly = false
    @State private var search = ""
    @State private var categories: [BlueprintCategory] = []

    @State private var result: CopyingResult?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var refreshCounter = 0
    @State private var sortOrder = [KeyPathComparator(\CopyingItem.perHourSort, order: .reverse)]
    @State private var selection: CopyingItem.ID?
    /// Base materials (ME 0, one run) per blueprint – for the right-click menu.
    @State private var baseMaterials: [Int: [MaterialNeed]] = [:]

    private struct LoadKey: Hashable {
        var hub, structure, category, group, search: String
        var ownedOnly: Bool
        var systemId, runsPerCopy, copies, refresh, rangeDays: Int
        var facilityTax: Double
    }

    private var loadKey: LoadKey {
        LoadKey(hub: hub, structure: structure, category: category, group: group,
                search: search.trimmingCharacters(in: .whitespaces), ownedOnly: ownedOnly,
                systemId: systemId, runsPerCopy: runsPerCopy,
                copies: copies, refresh: refreshCounter, rangeDays: rangeDays, facilityTax: facilityTax)
    }

    private var rows: [CopyingItem] { (result?.items ?? []).sorted(using: sortOrder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
                .zIndex(1)   // search suggestions draw over the table
            Divider()
            if let result {
                table(result)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Check Copies", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { refreshCounter += 1 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Reading public contracts in \(hub)'s region…")
                    Text("The first time takes a minute or two – after that only new contracts are read.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(result.map { "\($0.items.count) blueprints · \($0.copyOffersInRegion) copy contracts in \($0.regionName)" } ?? "")
        .task {
            if categories.isEmpty { categories = (try? await appState.backend.blueprintCategories()) ?? [] }
        }
        .task(id: loadKey) { await load() }
        .task {
            // Re-scan every 30 minutes while the page is open – that's how sales are spotted.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))
                guard !Task.isCancelled else { return }
                refreshCounter += 1
            }
        }
    }

    // MARK: Controls

    private var groupsForCategory: [BlueprintGroup] {
        categories.first { $0.name == category }?.groups ?? []
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SuggestingSearchField(prompt: "Search blueprints", text: $search) { text in
                    await appState.backend.suggestBuildable(text, category: category, group: group)
                }

                Picker("Category", selection: $category) {
                    Text("All").tag("")
                    if !categories.isEmpty { Divider() }
                    ForEach(categories) { item in Text("\(item.name) (\(item.count))").tag(item.name) }
                    if !categories.contains(where: { $0.name == category }) && !category.isEmpty {
                        Text(category).tag(category)
                    }
                }
                .frame(width: 230)
                .onChange(of: category) { _, _ in group = "" }

                Picker("Group", selection: $group) {
                    Text("All").tag("")
                    if !groupsForCategory.isEmpty { Divider() }
                    ForEach(groupsForCategory) { item in Text("\(item.name) (\(item.count))").tag(item.name) }
                    if !groupsForCategory.contains(where: { $0.name == group }) && !group.isEmpty {
                        Text(group).tag(group)
                    }
                }
                .frame(width: 260)
                .disabled(category.isEmpty)

                Spacer()
            }

            HStack(spacing: 12) {
                Picker("Sell copies in", selection: $hub) {
                    ForEach(TradeHub.allCases) { item in Text(item.rawValue).tag(item.rawValue) }
                }
                .frame(width: 200)
                .help("Public contracts in this hub's region are read for copy prices")

                HStack(spacing: 4) {
                    Text("Runs per copy")
                    TextField("Max", value: $runsPerCopy, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 55)
                    Stepper("Runs per copy", value: $runsPerCopy, in: 0...10_000).labelsHidden()
                }
                .help("0 = the most runs a copy of that blueprint can have")

                HStack(spacing: 4) {
                    Text("Copies")
                    TextField("Copies", value: $copies, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 45)
                    Stepper("Copies", value: $copies, in: 1...1000).labelsHidden()
                }

                Toggle("Only My Blueprints", isOn: $ownedOnly)

                PageKeyButton(columns: Self.columnKey)

                Spacer()

                Button("Refresh") { refreshCounter += 1 }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Table

    private func table(_ result: CopyingResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Copying an original to sell on public contracts in \(result.regionName). Science \(result.scienceLevel.roman) · Advanced Industry \(result.advancedIndustryLevel.roman) · \(result.labSlots) lab slot(s). \(result.trackingText)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Item", value: \.name) { item in
                    HStack(spacing: 6) {
                        if let product = item.productTypeId {
                            AsyncImage(url: PublicESIClient.typeIconURL(typeID: product, size: 32)) { image in
                                image.resizable()
                            } placeholder: { Color.clear }
                            .frame(width: 18, height: 18)
                        }
                        Text(item.name).fontWeight(item.isOwned ? .semibold : .regular)
                    }
                    .help((item.group.map { $0 + "\n\n" } ?? "") + item.batchHelp)
                }
                .width(min: 140, ideal: 190)

                TableColumn("Blueprint", value: \.ownedSort) { item in
                    Text(item.blueprintLabel)
                        .foregroundStyle(item.isOwned ? Color.primary : Color.secondary)
                }
                .width(min: 80, ideal: 100)

                TableColumn("Copy Time / Run") { item in
                    Text(item.copySecondsPerRun.durationLabel).monospacedDigit()
                        .help("Building one run takes \(item.buildSecondsPerRun.durationLabel) before skills.")
                }
                .width(min: 80, ideal: 100)

                TableColumn("Fee / Run") { item in
                    Text(item.feePerRun.iskShort).monospacedDigit()
                }
                .width(min: 60, ideal: 75)

                TableColumn("Price / Run", value: \.typicalSort) { item in
                    Text(item.typicalPerRun?.iskShort ?? "–").monospacedDigit()
                        .help(item.priceHelp)
                }
                .width(min: 70, ideal: 85)

                TableColumn("Verdict", value: \.perHourSort) { item in
                    Text(item.verdictText).monospacedDigit().fontWeight(.semibold)
                        .foregroundStyle(item.verdictColor)
                        .help(item.verdictHelp + "\n\n" + item.batchHelp)
                }
                .width(min: 110, ideal: 140)

                TableColumn("Margin / Run", value: \.marginSort) { item in
                    Text(item.marginPerRun?.iskShort ?? "–").monospacedDigit()
                        .foregroundStyle((item.marginPerRun ?? 0) < 0 ? Color.red : Color.primary)
                }
                .width(min: 70, ideal: 85)

                TableColumn("Contracts", value: \.offersSort) { item in
                    Text(item.contractsText).monospacedDigit()
                        .foregroundStyle(item.offers == 0 ? Color.secondary : Color.primary)
                        .help(item.priceHelp)
                }
                .width(min: 90, ideal: 140)
            }
            .contextMenu(forSelectionType: CopyingItem.ID.self) { ids in
                if let id = ids.first, let item = rows.first(where: { $0.id == id }) {
                    if let product = item.productTypeId {
                        ItemMenu(typeID: product, name: item.name)
                    }
                    Button("Show the Blueprint in Market") { appState.showInMarket(item.blueprintTypeId) }
                    MaterialsMenuContent(title: "Materials – 1 run, ME \(item.me)",
                                         materials: materialsAtME(baseMaterials[item.blueprintTypeId] ?? [], me: item.me))
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("Nothing Found", systemImage: "doc.on.doc",
                                           description: Text(ownedOnly ? "None of your originals match." : "No copyable blueprints match."))
                }
            }
        }
    }

    /// The "?" key: what each column means.
    static let columnKey: [(String, String)] = [
        ("Item", "What the blueprint builds. Bold = you own the original. Hover for the whole batch."),
        ("Blueprint", "Your original and its ME (copies inherit it), or Not owned – you'd need to buy the original first."),
        ("Copy Time / Run", "Lab time for one run of a copy, after Science and Advanced Industry."),
        ("Fee / Run", "Job fee for one run: 2% of the item's value × the copying cost index, plus taxes."),
        ("Price / Run", "Typical (median) contract price per run – copies at your ME or better when there are enough."),
        ("Verdict", "Copy +x/h = worth it, earning x per hour of lab time. Skip = copies sell for less than the fee. Too few = under 3 offers. No market = nobody sells copies."),
        ("Margin / Run", "Price per run − fee per run. Contracts have no sales tax."),
        ("Contracts", "Copies listed on public contracts in the region · ~ how many probably sold within the History range (vanished before expiry – tracked by the app between scans and kept)."),
    ]

    // MARK: Loading

    private func load() async {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        let key = loadKey
        var query: [URLQueryItem] = [
            URLQueryItem(name: "hub", value: key.hub),
            URLQueryItem(name: "structure", value: key.structure),
            URLQueryItem(name: "facility_tax", value: String(key.facilityTax)),
            URLQueryItem(name: "copies", value: String(max(1, key.copies))),
            URLQueryItem(name: "category", value: key.category),
            URLQueryItem(name: "group", value: key.group),
            URLQueryItem(name: "search", value: key.search),
            URLQueryItem(name: "owned_only", value: key.ownedOnly ? "true" : "false"),
        ]
        if key.runsPerCopy > 0 { query.append(URLQueryItem(name: "runs_per_copy", value: String(key.runsPerCopy))) }
        if key.systemId > 0 { query.append(URLQueryItem(name: "system_id", value: String(key.systemId))) }
        do {
            let newResult = try await appState.backend.blueprintCopying(query)
            guard !Task.isCancelled else { return }
            result = newResult
            errorMessage = nil
            baseMaterials = await appState.backend.baseMaterials(newResult.items.map(\.blueprintTypeId))
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
