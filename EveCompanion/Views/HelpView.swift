import SwiftUI

// MARK: - Built-in Help (16 Nov 2026)
//
// Articles are Markdown files named "Help-*.md" in Resources/Help (copied into the app).
// Each starts with a small header between two "---" lines:
//
//   ---
//   id: build-vs-sell            (unique; links use help:build-vs-sell)
//   title: Build vs Sell
//   section: Build               (where it sits in the contents)
//   also: Sell                   (other sections it is listed under – optional)
//   order: 50                    (position inside the section)
//   icon: scalemass              (SF Symbol)
//   page: buildVsSell            (SidebarItem raw value – "Help for This Page" and "Open Page")
//   keywords: profit, verdict    (extra search words; also listed in the A–Z index)
//   related: manufacturing, blueprint-payback
//   summary: One line shown under the title and in search results.
//   ---
//
// Body: "## " / "### " headings, "- " bullets (indent 2 spaces for a sub-bullet), "1. " numbered
// steps, "> " tip boxes, blank line between paragraphs, **bold**, *italic*, `code`, [links](help:id).

enum HelpWindow {
    static let id = "help"
}

struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let section: String
    let also: [String]
    let order: Int
    let icon: String
    let page: String?
    let keywords: [String]
    let related: [String]
    let summary: String
    let body: String
    /// Lower-cased text for searching.
    let titleLower: String
    let keywordsLower: String
    let bodyLower: String
}

struct HelpHit: Identifiable {
    let topic: HelpTopic
    let score: Int
    let snippet: String
    var id: String { topic.id }
}

struct HelpIndexEntry: Identifiable {
    let term: String
    let topicIDs: [String]
    var id: String { term }
}

/// Loads and searches the help articles.
enum HelpLibrary {
    /// Contents order. Sections not listed here go at the end, A–Z.
    static let sectionOrder = ["Getting Started", "Pilot", "Mine", "Build", "Sell", "Haul",
                               "Everywhere", "Walk-throughs", "Questions & Fixes", "Glossary"]

    static let topics: [HelpTopic] = load()
    static let byID: [String: HelpTopic] = {
        var map: [String: HelpTopic] = [:]
        for topic in topics { map[topic.id] = topic }
        return map
    }()

    static func topic(_ id: String) -> HelpTopic? { byID[id] }

    /// The article for a page of the app (for "Help for This Page").
    static func topic(forPage page: SidebarItem?) -> HelpTopic? {
        guard let page else { return nil }
        return topics.first { $0.page == page.rawValue }
    }

    static var sections: [String] {
        var names = Set<String>()
        for topic in topics {
            names.insert(topic.section)
            for other in topic.also { names.insert(other) }
        }
        return names.sorted { a, b in
            let ia = sectionOrder.firstIndex(of: a) ?? 999
            let ib = sectionOrder.firstIndex(of: b) ?? 999
            return ia != ib ? ia < ib : a < b
        }
    }

    static func topics(in section: String) -> [HelpTopic] {
        topics.filter { $0.section == section || $0.also.contains(section) }
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.title < $1.title }
    }

    // MARK: Loading

    private static func load() -> [HelpTopic] {
        var urls: [URL] = []
        urls += Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
        urls += Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: "Help") ?? []
        var seen = Set<String>()
        var result: [HelpTopic] = []
        for url in urls where url.lastPathComponent.hasPrefix("Help-") {
            guard !seen.contains(url.lastPathComponent) else { continue }
            seen.insert(url.lastPathComponent)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let topic = parse(text, fallbackID: url.deletingPathExtension().lastPathComponent) {
                result.append(topic)
            }
        }
        return result
    }

    static func parse(_ raw: String, fallbackID: String) -> HelpTopic? {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var header: [String: String] = [:]
        var body = text
        if text.hasPrefix("---\n") {
            let rest = text.dropFirst(4)
            if let end = rest.range(of: "\n---\n") {
                for line in rest[rest.startIndex..<end.lowerBound].split(separator: "\n") {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    header[key] = value
                }
                body = String(rest[end.upperBound...])
            }
        }
        func list(_ key: String) -> [String] {
            (header[key] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let id = header["id"] ?? fallbackID
        let title = header["title"] ?? id
        let keywords = list("keywords")
        let page = header["page"].flatMap { $0.isEmpty ? nil : $0 }
        return HelpTopic(
            id: id,
            title: title,
            section: header["section"] ?? "Other",
            also: list("also"),
            order: Int(header["order"] ?? "") ?? 100,
            icon: header["icon"] ?? "doc.text",
            page: page,
            keywords: keywords,
            related: list("related"),
            summary: header["summary"] ?? "",
            body: body,
            titleLower: title.lowercased(),
            keywordsLower: keywords.joined(separator: " ").lowercased(),
            bodyLower: (header["summary"] ?? "").lowercased() + "\n" + body.lowercased()
        )
    }

    // MARK: Searching

    static func words(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Every word must appear somewhere in the article; titles and keywords count most.
    static func search(_ query: String) -> [HelpHit] {
        let terms = words(query)
        guard !terms.isEmpty else { return [] }
        var hits: [HelpHit] = []
        for topic in topics {
            var score = 0
            var all = true
            for term in terms {
                let inTitle = topic.titleLower.contains(term)
                let inKeywords = topic.keywordsLower.contains(term)
                let bodyCount = min(topic.bodyLower.components(separatedBy: term).count - 1, 6)
                if !inTitle && !inKeywords && bodyCount == 0 { all = false; break }
                if topic.titleLower == term { score += 30 }
                if topic.titleLower.hasPrefix(term) { score += 8 }
                if inTitle { score += 14 }
                if inKeywords { score += 8 }
                score += bodyCount
            }
            guard all else { continue }
            if topic.titleLower.contains(terms.joined(separator: " ")) { score += 10 }
            hits.append(HelpHit(topic: topic, score: score, snippet: snippet(topic, terms: terms)))
        }
        return hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.topic.title < $1.topic.title }
    }

    /// The first line of the article that mentions a search word, shortened and without Markdown marks.
    private static func snippet(_ topic: HelpTopic, terms: [String]) -> String {
        let lines = topic.body.split(separator: "\n").map { plain(String($0)) }.filter { !$0.isEmpty }
        for term in terms {
            if let line = lines.first(where: { $0.lowercased().contains(term) }) {
                return shorten(line, around: term)
            }
        }
        return topic.summary
    }

    private static func shorten(_ line: String, around term: String) -> String {
        guard line.count > 150, let range = line.lowercased().range(of: term) else { return line }
        let at = line.lowercased().distance(from: line.lowercased().startIndex, to: range.lowerBound)
        let start = min(max(0, at - 50), max(0, line.count - 150))
        let begin = line.index(line.startIndex, offsetBy: start)
        let end = line.index(begin, offsetBy: min(150, line.distance(from: begin, to: line.endIndex)))
        var text = String(line[begin..<end])
        if start > 0 { text = "…" + text }
        if end < line.endIndex { text += "…" }
        return text
    }

    /// Text without Markdown marks (for snippets).
    static func plain(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["### ", "## ", "# ", "- ", "* ", "> "] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if let attributed = try? AttributedString(markdown: s) { s = String(attributed.characters) }
        return s
    }

    // MARK: A–Z index

    /// Every title and keyword, A–Z, with the articles it leads to.
    static let index: [HelpIndexEntry] = {
        var map: [String: (display: String, ids: [String])] = [:]
        func add(_ term: String, _ id: String) {
            let key = term.lowercased()
            guard !key.isEmpty else { return }
            var entry = map[key] ?? (display: term, ids: [])
            if !entry.ids.contains(id) { entry.ids.append(id) }
            map[key] = entry
        }
        for topic in topics {
            add(topic.title, topic.id)
            for keyword in topic.keywords { add(keyword, topic.id) }
        }
        return map.values
            .map { HelpIndexEntry(term: $0.display, topicIDs: $0.ids) }
            .sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }()
}

// MARK: - Shared state (which article is open, which page the main window shows)

@MainActor @Observable
final class HelpCenter {
    static let shared = HelpCenter()

    /// Contents row: "section/topicID", "search/topicID" or "index".
    var selection: String? = "index"
    var query = ""
    /// The page the main window is showing (kept up to date by ContentView).
    var currentPage: SidebarItem?
    /// Articles visited, for Back.
    var history: [String] = []

    static let indexRow = "index"

    var topicID: String? {
        guard let selection, selection != Self.indexRow else { return nil }
        return selection.split(separator: "/", maxSplits: 1).last.map(String.init)
    }

    func show(_ id: String) {
        guard let topic = HelpLibrary.topic(id) else { return }
        if let current = selection, current != "\(topic.section)/\(id)" { history.append(current) }
        query = ""
        selection = "\(topic.section)/\(id)"
    }

    func showCurrentPage() {
        if let topic = HelpLibrary.topic(forPage: currentPage) { show(topic.id) }
    }

    func back() {
        guard let last = history.popLast() else { return }
        query = ""
        selection = last
    }
}

// MARK: - Help menu

struct HelpMenuButtons: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("\(AppInfo.name) Help") {
            let center = HelpCenter.shared
            if center.selection == nil { center.selection = HelpCenter.indexRow }
            openWindow(id: HelpWindow.id)
        }
        .keyboardShortcut("?", modifiers: .command)

        Button("Help for This Page") {
            HelpCenter.shared.showCurrentPage()
            openWindow(id: HelpWindow.id)
        }
        .keyboardShortcut("?", modifiers: [.command, .option])

        Divider()

        Button("Getting Started") {
            HelpCenter.shared.show("welcome")
            openWindow(id: HelpWindow.id)
        }
        Button("Questions & Fixes") {
            HelpCenter.shared.show("troubleshooting")
            openWindow(id: HelpWindow.id)
        }
        Button("Glossary") {
            HelpCenter.shared.show("glossary")
            openWindow(id: HelpWindow.id)
        }
    }
}

// MARK: - Help window

struct HelpView: View {
    @State private var center = HelpCenter.shared

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .searchable(text: $center.query, placement: .sidebar, prompt: "Search help")
        .environment(\.openURL, OpenURLAction { url in
            let text = url.absoluteString
            if text.hasPrefix("help:") {
                center.show(String(text.dropFirst(5)))
                return .handled
            }
            return .systemAction
        })
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    center.back()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(center.history.isEmpty)
                .help("Back to the previous article")
            }
        }
    }

    // MARK: Contents / search results

    @ViewBuilder
    private var sidebar: some View {
        let hits = HelpLibrary.search(center.query)
        let header: String = hits.isEmpty ? "No matches" : "\(hits.count) result\(hits.count == 1 ? "" : "s")"
        List(selection: $center.selection) {
            if !center.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section(header) {
                    ForEach(hits) { hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(hit.topic.title, systemImage: hit.topic.icon)
                                .font(.body.weight(.medium))
                            Text(hit.topic.section)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(hit.snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                        .tag("search/\(hit.topic.id)")
                    }
                }
            } else {
                Label("A–Z Index", systemImage: "list.bullet.indent")
                    .tag(HelpCenter.indexRow)
                ForEach(HelpLibrary.sections, id: \.self) { section in
                    Section(section) {
                        ForEach(HelpLibrary.topics(in: section)) { topic in
                            Label(topic.title, systemImage: topic.icon)
                                .tag("\(section)/\(topic.id)")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Article

    @ViewBuilder
    private var detail: some View {
        if HelpLibrary.topics.isEmpty {
            ContentUnavailableView("Help Isn't Installed",
                                   systemImage: "questionmark.circle",
                                   description: Text("The help articles weren't found in the app. Rebuilding the app should put them back."))
        } else if let id = center.topicID, let topic = HelpLibrary.topic(id) {
            HelpArticleView(topic: topic, highlight: HelpLibrary.words(center.query))
                .id(topic.id)
        } else {
            HelpIndexView()
        }
    }
}

// MARK: - One article

private struct HelpArticleView: View {
    @Environment(AppState.self) private var appState
    let topic: HelpTopic
    let highlight: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(([topic.section] + topic.also).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let raw = topic.page, let page = SidebarItem(rawValue: raw) {
                        Button {
                            appState.goToPage = page
                        } label: {
                            Label("Open \(page.title)", systemImage: page.systemImage)
                        }
                        .controlSize(.small)
                        .help("Show this page in the main window")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: topic.icon)
                        .font(.title)
                        .foregroundStyle(.tint)
                    Text(topic.title)
                        .font(.largeTitle.bold())
                }
                if !topic.summary.isEmpty {
                    Text(HelpText.inline(topic.summary, highlight: highlight))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Divider()
                ForEach(Array(HelpText.blocks(topic.body).enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block, highlight: highlight)
                }
                if !relatedTopics.isEmpty {
                    Divider().padding(.top, 8)
                    Text("See Also")
                        .font(.headline)
                    FlowLinks(topics: relatedTopics)
                }
            }
            .textSelection(.enabled)
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var relatedTopics: [HelpTopic] {
        topic.related.compactMap { HelpLibrary.topic($0) }
    }
}

/// Small link buttons to other articles, wrapped over lines.
private struct FlowLinks: View {
    let topics: [HelpTopic]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 170), alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(topics) { topic in
                Button {
                    HelpCenter.shared.show(topic.id)
                } label: {
                    Label(topic.title, systemImage: topic.icon)
                }
                .buttonStyle(.link)
            }
        }
    }
}

// MARK: - A–Z index page

private struct HelpIndexView: View {
    var body: some View {
        let groups = Dictionary(grouping: HelpLibrary.index) { entry -> String in
            let first = entry.term.prefix(1).uppercased()
            return first.rangeOfCharacter(from: .letters) == nil ? "#" : first
        }
        let letters = groups.keys.sorted()
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("A–Z Index")
                        .font(.largeTitle.bold())
                    Text("Every page, feature and word explained in this help. Click one to read about it – or type in the search box to look through every article.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(letters, id: \.self) { letter in
                            Button(letter) { withAnimation { proxy.scrollTo(letter, anchor: .top) } }
                                .buttonStyle(.link)
                        }
                    }
                    .font(.headline)
                    ForEach(letters, id: \.self) { letter in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(letter)
                                .font(.title2.bold())
                                .padding(.top, 6)
                                .id(letter)
                            ForEach(groups[letter] ?? []) { entry in
                                IndexRow(entry: entry)
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct IndexRow: View {
    let entry: HelpIndexEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.term)
                .frame(minWidth: 180, alignment: .leading)
            Text("→")
                .foregroundStyle(.secondary)
            ForEach(entry.topicIDs, id: \.self) { id in
                if let topic = HelpLibrary.topic(id) {
                    Button(topic.title) { HelpCenter.shared.show(id) }
                        .buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Simple Markdown blocks

enum HelpBlock {
    case heading(String, Int)
    case paragraph(String)
    case bullet(String, Int)
    case step(String, Int)
    case tip(String)
    case rule
}

enum HelpText {
    static func blocks(_ body: String) -> [HelpBlock] {
        var result: [HelpBlock] = []
        var paragraph: [String] = []
        var tip: [String] = []

        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !tip.isEmpty { result.append(.tip(tip.joined(separator: " "))); tip = [] }
        }

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            if trimmed.isEmpty { flush(); continue }
            if trimmed == "---" { flush(); result.append(.rule); continue }
            if trimmed.hasPrefix("### ") { flush(); result.append(.heading(String(trimmed.dropFirst(4)), 3)); continue }
            if trimmed.hasPrefix("## ") { flush(); result.append(.heading(String(trimmed.dropFirst(3)), 2)); continue }
            if trimmed.hasPrefix("# ") { flush(); result.append(.heading(String(trimmed.dropFirst(2)), 2)); continue }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
                tip.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush()
                result.append(.bullet(String(trimmed.dropFirst(2)), indent >= 2 ? 1 : 0))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), let number = Int(trimmed[trimmed.startIndex..<dot]),
               trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                result.append(.step(String(trimmed[trimmed.index(dot, offsetBy: 2)...]), number))
                continue
            }
            if !tip.isEmpty { flush() }
            paragraph.append(trimmed)
        }
        flush()
        return result
    }

    /// Inline Markdown (bold, italic, code, links) with search words highlighted.
    static func inline(_ text: String, highlight: [String]) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for word in highlight where word.count >= 2 {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let found = attributed[searchStart..<attributed.endIndex].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                attributed[found].backgroundColor = Color.yellow.opacity(0.35)
                searchStart = found.upperBound
            }
        }
        return attributed
    }
}

private struct HelpBlockView: View {
    let block: HelpBlock
    let highlight: [String]

    var body: some View {
        switch block {
        case .heading(let text, let level):
            Text(HelpText.inline(text, highlight: highlight))
                .font(level == 2 ? Font.title2.bold() : Font.headline)
                .padding(.top, level == 2 ? 10 : 4)
        case .paragraph(let text):
            Text(HelpText.inline(text, highlight: highlight))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        case .bullet(let text, let level):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: level == 0 ? "•" : "◦")
                    .foregroundStyle(.secondary)
                Text(HelpText.inline(text, highlight: highlight))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            .padding(.leading, CGFloat(8 + level * 20))
        case .step(let text, let number):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(HelpText.inline(text, highlight: highlight))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            .padding(.leading, 4)
        case .tip(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.yellow)
                Text(HelpText.inline(text, highlight: highlight))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }
}
