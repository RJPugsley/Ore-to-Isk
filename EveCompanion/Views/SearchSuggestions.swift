import SwiftUI

// MARK: - Search with suggestions

/// The app's search box with predictive suggestions: as you type, up to 8 matches drop down
/// underneath. Click one (or use ↑ ↓ and Return) to fill it in; Escape closes the list.
/// Put `.zIndex(1)` on the bar that holds it so the list draws over the table below.
struct SuggestingSearchField: View {
    let prompt: String
    @Binding var text: String
    var width: CGFloat = 240
    /// Suggestions for what's typed so far (called after a short pause in typing).
    let suggest: (String) async -> [String]
    /// How many suggestions to show (the list scrolls past about 12).
    var maxShown = 8
    /// Optional icon per suggestion: (SF Symbol, colour).
    var icon: ((String) -> (String, Color)?)? = nil
    /// Keep a suggestion that matches what's typed exactly (e.g. the system at the top of its stations).
    var keepExactMatch = false

    @State private var suggestions: [String] = []
    @State private var highlighted: Int?
    /// Height of the suggestion rows, measured – the box is exactly that tall (up to 10 rows, then it scrolls).
    @State private var listHeight: CGFloat = 0
    @State private var showing = false
    @State private var picking = false
    @FocusState private var focused: Bool

    /// Tall enough for every row, but no more than 10 – past that the list scrolls.
    private var boxHeight: CGFloat {
        let rows = visible.count
        guard rows > 0, listHeight > 0 else { return 30 }
        let perRow = (listHeight - 8) / CGFloat(rows)   // 8 = the list's padding
        return rows > 10 ? perRow * 10 + 8 : listHeight
    }

    private var visible: [String] {
        Array(suggestions.filter { keepExactMatch || $0.caseInsensitiveCompare(text) != .orderedSame }.prefix(maxShown))
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onKeyPress(.downArrow) {
                    guard showing, !visible.isEmpty else { return .ignored }
                    highlighted = min((highlighted ?? -1) + 1, visible.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard showing, let current = highlighted else { return .ignored }
                    highlighted = current > 0 ? current - 1 : nil
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard showing else { return .ignored }
                    showing = false
                    return .handled
                }
                .onSubmit {
                    if showing, let index = highlighted, visible.indices.contains(index) { pick(visible[index]) }
                    showing = false
                }
            if !text.isEmpty {
                Button {
                    text = ""
                    showing = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: width)
        .overlay(alignment: .topLeading) {
            if showing && !visible.isEmpty {
                ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible.indices, id: \.self) { index in
                        Button {
                            pick(visible[index])
                        } label: {
                            HStack(spacing: 6) {
                                if let icon, let mark = icon(visible[index]) {
                                    Image(systemName: mark.0).foregroundStyle(mark.1).frame(width: 16)
                                }
                                Text(visible[index]).lineLimit(1)
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .background(index == highlighted ? Color.accentColor.opacity(0.3) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in if inside { highlighted = index } }
                    }
                }
                .padding(4)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: SuggestionListHeight.self, value: geo.size.height)
                })
                }
                .onPreferenceChange(SuggestionListHeight.self) { listHeight = $0 }
                .frame(height: boxHeight)
                // Wide enough for long station names; a solid background so nothing shows through.
                .frame(minWidth: width, maxWidth: max(width, 460), alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .offset(y: 32)
            }
        }
        .zIndex(10)
        .task(id: text) {
            if picking {   // the text changed because a suggestion was picked – don't reopen
                picking = false
                return
            }
            let query = text.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else {
                suggestions = []
                showing = false
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = await suggest(query)
            guard !Task.isCancelled else { return }
            suggestions = found
            highlighted = nil
            showing = focused && !found.isEmpty
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused {
                // Let a click on a suggestion land before the list closes.
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    if !focused { showing = false }
                }
            }
        }
    }

    private func pick(_ value: String) {
        picking = true
        text = value
        showing = false
        highlighted = nil
    }
}

/// Local suggestions from a list of names: names starting with the text first, then containing it.
func localSuggestions(_ query: String, from names: [String], limit: Int = 8) -> [String] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return [] }
    var seen = Set<String>()
    let unique = names.filter { seen.insert($0).inserted }
    let starts = unique.filter { $0.range(of: q, options: [.caseInsensitive, .anchored]) != nil }.sorted()
    let contains = unique.filter {
        $0.localizedCaseInsensitiveContains(q) && $0.range(of: q, options: [.caseInsensitive, .anchored]) == nil
    }.sorted()
    return Array((starts + contains).prefix(limit))
}

/// Height of the suggestion rows inside the drop-down.
private struct SuggestionListHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
