import SwiftUI

extension Color {
    /// Deliberately darker than the system window background — the culling grid and editor
    /// sidebar both use this so photos and controls read against a near-black backdrop instead
    /// of macOS's stock dark-mode gray.
    static let workspaceBackground = Color(red: 0.055, green: 0.055, blue: 0.06)
    /// A touch lighter than `workspaceBackground` — used for the navigation sidebar (Library /
    /// Scenes list) so it reads as a distinct layer from the content area next to it, while
    /// still being much darker than macOS's stock sidebar material.
    static let sidebarBackground = Color(red: 0.09, green: 0.09, blue: 0.095)
    /// Backdrop behind the photo in `EditorView`'s preview pane — a neutral ~18% gray rather than
    /// pure black, matching Darktable's darkroom background. A pure-black surround exaggerates
    /// shadow depth and saturation via simultaneous contrast, biasing color/exposure judgment
    /// while editing; this is dark enough to fit the app's theme without that bias.
    static let editorPreviewBackground = Color(red: 0.18, green: 0.18, blue: 0.18)
}
