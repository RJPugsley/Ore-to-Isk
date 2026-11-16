import SwiftUI
import AppKit

/// Right-click menu on a blueprint row: the materials it needs, plus a copy in EVE's
/// Multibuy format ("Name quantity" per line) so you can paste it straight into the game.
struct MaterialsMenuContent: View {
    let title: String
    let materials: [MaterialNeed]

    var body: some View {
        if materials.isEmpty {
            Text("No materials listed")
        } else {
            Section(title) {
                ForEach(materials.indices, id: \.self) { index in
                    Text("\(materials[index].quantity.short)  \(materials[index].name)")
                }
            }
            Divider()
            Button("Copy for Multibuy") {
                let text = materials.map { "\($0.name) \($0.quantity)" }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

/// Blueprint ME applied to base (ME 0) quantities for one run – the game's rounding,
/// before any structure or rig bonus.
func materialsAtME(_ base: [MaterialNeed], me: Int, runs: Int = 1) -> [MaterialNeed] {
    base.map { m in
        let exact = Double(m.quantity * runs) * (1 - Double(me) / 100)
        let rounded = (exact * 100).rounded() / 100
        return MaterialNeed(name: m.name, quantity: max(runs, Int(rounded.rounded(.up))))
    }
    .sorted { $0.quantity > $1.quantity }
}
