import SwiftUI

/// The app's Settings window (`Settings { SettingsView() }` in `PhotoCullApp`) — opened via the
/// standard macOS "PhotoCull > Settings…" menu item / Cmd-,. Currently a single editor-preferences
/// pane; add more `Section`s here (or split into a `TabView` of panes) as more settings arrive
/// rather than stacking unrelated toggles into `EditorFooterActions` or similar per-feature spots.
struct SettingsView: View {
    @AppStorage(AppSettingsKey.whiteBalanceControlStyle) private var whiteBalanceStyle: WhiteBalanceControlStyle = .classic

    var body: some View {
        Form {
            Section("Editor") {
                Picker("White Balance Control", selection: $whiteBalanceStyle) {
                    ForEach(WhiteBalanceControlStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 160)
    }
}
