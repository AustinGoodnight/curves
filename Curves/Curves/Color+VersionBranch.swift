import SwiftUI

extension Color {
    /// A stable color per branch name, for `VersionTreeView`'s graph — deliberately a manual sum-
    /// of-scalars hash rather than `Hashable`/`Hasher`, whose seed is randomized per process; this
    /// needs "main" to look the same color every time the app launches, not just within one run.
    static func versionBranch(_ name: String) -> Color {
        let palette: [Color] = [.accentColor, .orange, .green, .purple, .pink, .teal, .yellow, .indigo]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}
