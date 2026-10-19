import SwiftUI
import AppKit

/// A plain sRGB-component color, `Codable` for persistence — `SwiftUI.Color` itself isn't
/// `Codable`, so every customizable color in `UIColorScheme`/`NamedColorScheme` is stored as one
/// of these and converted to/from `Color` at the UI boundary (`color`/`init(_:)`).
struct RGBAColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Extracts sRGB components via `NSColor` — the only reliable way to pull numeric components
    /// back out of an arbitrary `SwiftUI.Color`, including ones a `ColorPicker` hands back that
    /// aren't guaranteed to already be in a component-addressable space.
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        red = Double(ns.redComponent)
        green = Double(ns.greenComponent)
        blue = Double(ns.blueComponent)
        alpha = Double(ns.alphaComponent)
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// Every user-customizable UI chrome color, persisted as one unit by `ColorSchemeStore` and saved/
/// restored wholesale as one entry in a `NamedColorScheme` preset.
struct UIColorScheme: Codable, Equatable {
    /// The main panel background (navigation sidebar, editor sidebar, bottom bars, window
    /// chrome) — was the fixed `Color.sidebarBackground` constant in `Color+Workspace.swift`.
    var sidebarBackground: RGBAColor
    /// The culling grid's content-area background — was `Color.workspaceBackground`.
    var workspaceBackground: RGBAColor
    /// The recessed "groove" fill/border shared by every slider track, the RGB Curve graph, and
    /// the Filmic module button — was `Color.recessedTrackBackground`.
    var recessedTrackBackground: RGBAColor
    /// The app's own accent color — independent of the system Accent Color preference (which is
    /// all `Color.accentColor` reads used to follow). Also drives `StoplightToggle`'s "on" color.
    var accentColor: RGBAColor
    /// The selectable swatches in `EditorView`'s preview-background palette row — always exactly
    /// `EditorView.previewBackgroundSwatchCount` (6) entries; the Settings UI only ever edits one
    /// in place; nothing changes the count.
    var previewBackgroundPalette: [RGBAColor]

    static let `default` = UIColorScheme(
        sidebarBackground: RGBAColor(red: 0.075, green: 0.075, blue: 0.08),
        workspaceBackground: RGBAColor(red: 0.055, green: 0.055, blue: 0.06),
        recessedTrackBackground: RGBAColor(red: 0.055, green: 0.055, blue: 0.055),
        accentColor: RGBAColor(red: 1, green: 0.231, blue: 0.188),
        previewBackgroundPalette: [
            RGBAColor(red: 0.18, green: 0.18, blue: 0.18),
            RGBAColor(red: 0, green: 0, blue: 0),
            RGBAColor(red: 0.15, green: 0.15, blue: 0.15),
            RGBAColor(red: 0.35, green: 0.35, blue: 0.35),
            RGBAColor(red: 0.65, green: 0.65, blue: 0.65),
            RGBAColor(red: 1, green: 1, blue: 1),
        ]
    )
}

/// One user-saved color scheme, listed in `SettingsView`'s "Presets" section — apply it to make
/// its `scheme` the live one, or delete it. Distinct from "Reset to Default", which restores
/// `UIColorScheme.default` without needing a saved preset.
struct NamedColorScheme: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var scheme: UIColorScheme

    init(id: UUID = UUID(), name: String, scheme: UIColorScheme) {
        self.id = id
        self.name = name
        self.scheme = scheme
    }
}
