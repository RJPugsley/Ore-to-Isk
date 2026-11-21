import SwiftUI
import AppKit

// MARK: - Search with suggestions

/// The app's search box with predictive suggestions: as you type, up to 8 matches drop down
/// underneath. Click one (or use ↑ ↓ and Return) to fill it in; Escape closes the list.
/// The list opens in a small floating window (`SuggestionPanelAnchor`), so it is always on top and solid.
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
    @State private var showing = false
    @State private var picking = false
    @FocusState private var focused: Bool

    /// Each suggestion row is this tall; the box fits up to 10 rows, then scrolls.
    private static let rowHeight: CGFloat = 24
    private var boxHeight: CGFloat {
        CGFloat(min(visible.count, 10)) * Self.rowHeight + 8   // 8 = the list's padding
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
        // The list opens in its own small window attached to this one, so it is always on top
        // of everything on the page and never shows anything through it.
        .background(SuggestionPanelAnchor(isShown: showing && !visible.isEmpty, content: AnyView(suggestionList)))
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

    private var suggestionList: some View {
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
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(index == highlighted ? Color.accentColor.opacity(0.3) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in if inside { highlighted = index } }
                }
            }
            .padding(4)
        }
        .scrollIndicators(visible.count > 10 ? .automatic : .never)
        .frame(height: boxHeight)
        // Wide enough for long station names.
        .frame(minWidth: width, maxWidth: max(width, 460), alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

// MARK: - Floating suggestion panel

/// Shows `content` in a borderless child window just under the view it's attached to.
/// The main window stays key, so typing carries on in the search field.
struct SuggestionPanelAnchor: NSViewRepresentable {
    let isShown: Bool
    let content: AnyView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        if isShown {
            // After layout, so the anchor's position on screen is final.
            DispatchQueue.main.async { coordinator.show(content, under: view) }
        } else {
            coordinator.hide()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.hide()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        private var panel: SuggestionPanel?
        private var hosting: FirstClickHostingView?
        private weak var parent: NSWindow?

        func show(_ content: AnyView, under anchor: NSView) {
            guard let window = anchor.window else { return }
            let panel = self.panel ?? makePanel()
            if let hosting {
                hosting.rootView = content
            } else {
                let view = FirstClickHostingView(rootView: content)
                hosting = view
                panel.contentView = view
            }
            let size = hosting?.fittingSize ?? .zero
            let inWindow = anchor.convert(anchor.bounds, to: nil)
            let onScreen = window.convertToScreen(inWindow)
            panel.setFrame(NSRect(x: onScreen.minX, y: onScreen.minY - 3 - size.height,
                                  width: size.width, height: size.height), display: true)
            if parent !== window {
                parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
                parent = window
            }
            panel.orderFront(nil)
        }

        func hide() {
            guard let panel else { return }
            parent?.removeChildWindow(panel)
            parent = nil
            panel.orderOut(nil)
        }

        private func makePanel() -> SuggestionPanel {
            let panel = SuggestionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            self.panel = panel
            return panel
        }
    }
}

/// Never takes keyboard focus away from the window with the search field.
final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a suggestion works first time, without having to activate the panel.
final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
