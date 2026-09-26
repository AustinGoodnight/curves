import Foundation

/// Which style the White Balance control in `ColorBalanceBarView` renders as — a user preference
/// read via `@AppStorage`, not a per-photo edit (nothing here is stored on `PhotoAsset`/`Stage`).
/// `.classic` is the original pair of vertical gradient faders (`VerticalGradientSlider`); `.xy`
/// is `XYWhiteBalanceControl`, a single 2D pad with Tint on the horizontal axis and Temp on the
/// vertical axis. Chosen in `SettingsView`.
enum WhiteBalanceControlStyle: String, CaseIterable, Identifiable {
    case classic
    case xy

    var id: Self { self }

    var label: String {
        switch self {
        case .classic: return "Classic Sliders"
        case .xy: return "XY Pad"
        }
    }
}

/// `UserDefaults` keys backing `@AppStorage` reads scattered across the app — kept in one place so
/// a key string typo doesn't silently split what's meant to be one setting into two.
enum AppSettingsKey {
    static let whiteBalanceControlStyle = "whiteBalanceControlStyle"
    /// Settings > Developer — shows in-progress design comparison panels in the editor (e.g. the
    /// "Tone Mapper Styles" panel) and unlocks the Component Gallery window.
    static let developerMode = "developerMode"
}
