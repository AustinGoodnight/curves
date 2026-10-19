import SwiftUI

/// Candidate looks for Color Zones' hue-axis graph (`CurveEditorControl` with `showHueAxis`),
/// compared via Developer Mode's menu in the Color Zones toolbar and in the Component Gallery.
/// Every style except `.original` draws hue from `WheelPalette`'s Color Zones axis — the Lab hue
/// the kernel really selects at each x, at one shared perceptual lightness.
enum HueGraphStyle: String, CaseIterable, Identifiable {
    case original
    case centerStripe
    case tintedLine
    case eqBars
    case faintWash
    case photoStrip

    var id: Self { self }

    var label: String {
        switch self {
        case .original: "Original · Spectrum Background"
        case .centerStripe: "A · Center Stripe + Tint"
        case .tintedLine: "B · Hue-Colored Curve"
        case .eqBars: "C · EQ Bars"
        case .faintWash: "D · Faint Wash"
        case .photoStrip: "E · Photo Hue Strip"
        }
    }
}

/// What sits *behind* Color Zones' graph — compared alongside `HueGraphStyle`. The default
/// `.recessed` fill is lighter than the bar around it in the current color scheme, which reads as
/// a large grey slab at this graph's size (the WB pad and wheel faces use the same fill but are
/// small). The rest drop or rework the box.
enum HueGraphBackground: String, CaseIterable, Identifiable {
    case recessed
    case outline
    case sunken
    case borderless
    case cornerMarks
    case hueLanes

    var id: Self { self }

    var label: String {
        switch self {
        case .recessed: "Recessed Fill (current)"
        case .outline: "Outline + Dot Grid"
        case .sunken: "Sunken (darker than bar)"
        case .borderless: "No Box · Edge Ticks"
        case .cornerMarks: "Corner Marks + Dot Grid"
        case .hueLanes: "Hue Lanes"
        }
    }
}

extension WheelPalette {
    /// `colorZonesAxis`'s stops as plain colors, for `Canvas` drawing that picks a color per x.
    static let colorZonesColors: [Color] = colorZonesAxis.stops.map(\.color)

    /// The real Lab hue at Color Zones x-position `x` (0...1).
    static func colorZonesColor(at x: Double) -> Color {
        let index = Int((min(max(x, 0), 1) * Double(colorZonesColors.count - 1)).rounded())
        return colorZonesColors[index]
    }
}
