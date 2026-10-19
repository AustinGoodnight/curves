import Foundation

/// Which layout the White Balance control in `ColorBalanceBarView` renders as — a user preference
/// read via `@AppStorage`, not a per-photo edit (nothing here is stored on `PhotoAsset`/`Stage`).
/// `.classic` is the Temp/Tint stripe faders (`WhiteBalanceFaderPair`); `.xy` is the single 2D
/// `WhiteBalancePad`. Chosen in `SettingsView`.
enum WhiteBalanceControlStyle: String, CaseIterable, Identifiable {
    case classic
    case xy

    var id: Self { self }

    var label: String {
        switch self {
        case .classic: return "Faders"
        case .xy: return "Pad"
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
    /// `ColorWheelStyle` for the bottom bar's color wheels — picked from Developer Mode's "Wheel
    /// Style" menu while the candidates are being compared.
    static let colorWheelStyle = "colorWheelStyle"
    /// `HueGraphStyle` for Color Zones' graph — same Developer Mode comparison as above.
    static let hueGraphStyle = "hueGraphStyle"
    /// `HueGraphBackground` for Color Zones' graph — same comparison, picked from the same menu.
    static let hueGraphBackground = "hueGraphBackground"
}
