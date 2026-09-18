import SwiftUI
import AppKit

extension Color {
    /// Backdrop behind the photo in `EditorView`'s preview pane — a neutral ~18% gray rather than
    /// pure black, matching Darktable's darkroom background. A pure-black surround exaggerates
    /// shadow depth and saturation via simultaneous contrast, biasing color/exposure judgment
    /// while editing; this is dark enough to fit the app's theme without that bias. Not part of
    /// `UIColorScheme`/`ColorSchemeStore` — it's the fixed default the preview pane starts on
    /// before the user picks a swatch, distinct from the customizable swatches themselves
    /// (`ColorSchemeStore.previewBackgroundPalette`).
    static let editorPreviewBackground = Color(red: 0.18, green: 0.18, blue: 0.18)

    /// The mat behind a grid thumbnail (`PhotoThumbnailCell`'s placeholder/letterbox fill) — a
    /// static solid color, not `.gray.opacity(0.15)` layered over whatever's beneath it. A
    /// translucent fill's rendered color depends on what's stacked under it (the scene mat, the
    /// workspace background, a hover state), so it could shift instead of reading as one consistent
    /// mat color across cells; matches `.gray.opacity(0.15)`'s previous look against this app's dark
    /// workspace background.
    static let thumbnailMatBackground = Color(red: 0.14, green: 0.14, blue: 0.14)

    /// The shared saturation/brightness every hue-based control background in `ColorBalanceBarView`
    /// (the 4 color wheels' arcs, Color Zones' hue-axis strip, the WB/Chr/Vib/Sat gradient faders,
    /// the XY white balance pad) is normalized onto via `normalizedVividness(_:)` below — matches
    /// `CurveEditorControl.hueSpectrum`'s existing level, already proven at Color Zones' scale.
    /// Before this existed, each control picked its own colors independently: the wheels used raw
    /// `Color(hue:saturation: 1, brightness: 1)`, Color Zones used 0.85/0.95, and the linear faders/
    /// XY pad used literal Apple system-color RGB triples — whose *own* saturation/brightness varies
    /// hue to hue (systemGreen's HSB is roughly (0.77, 0.82), notably duller than systemBlue's or
    /// systemOrange's (~0.96, 1.0)), so the green stop in every gradient that used it read flatter
    /// than its neighbors even before comparing across controls.
    static let controlSpectrumSaturation: Double = 0.85
    static let controlSpectrumBrightness: Double = 0.95

    /// Re-expresses `self` at `controlSpectrumSaturation`/`controlSpectrumBrightness` while keeping
    /// its hue — lets every gradient/spectrum control keep picking colors by name (`.systemBlue`,
    /// `.systemGreen`, …, for the direction/meaning each hue already encodes) while actually
    /// rendering at one shared vividness, rather than inheriting whatever saturation/brightness
    /// that named color happens to natively have.
    func normalizedVividness() -> Color {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        ns.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: Double(hue), saturation: Color.controlSpectrumSaturation, brightness: Color.controlSpectrumBrightness)
    }
}
