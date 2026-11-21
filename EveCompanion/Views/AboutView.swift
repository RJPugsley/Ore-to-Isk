import AppKit
import SwiftUI

/// App name as people see it (on disk it's "EVE Ore to ISK" / eve_ore_to_isk – no colon in file names).
enum AppInfo {
    static let name = "EVE: Ore to ISK"
    static let stage = "beta"

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.4"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) \(stage) (build \(build))"
    }
}

/// About window (app menu › About EVE: Ore to ISK).
struct AboutView: View {
    static let id = "about"

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text(AppInfo.name).font(.title2.weight(.semibold))
                Text(AppInfo.version).font(.callout).foregroundStyle(.secondary)
            }

            Text("Mine, refine, build, sell and haul – see what pays before you undock.")
                .font(.callout)
                .multilineTextAlignment(.center)

            Button("Show Data Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([EngineSettings.appFolder])
            }
            .help(EngineSettings.appFolder.path(percentEncoded: false))

            Divider()

            Text("""
            EVE Online and the EVE logo are the registered trademarks of CCP hf. \
            All rights are reserved worldwide. This app is not affiliated with or endorsed by CCP hf. \
            It was created under the EVE Developer License Agreement and uses data from EVE's ESI, \
            the EVE Static Data Export and zKillboard.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 380)
    }
}
