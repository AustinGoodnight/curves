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
}
