import SwiftUI

extension Color {
    /// Backdrop behind the photo in `EditorView`'s preview pane — a neutral ~18% gray rather than
    /// pure black, matching Darktable's darkroom background. A pure-black surround exaggerates
    /// shadow depth and saturation via simultaneous contrast, biasing color/exposure judgment
    /// while editing; this is dark enough to fit the app's theme without that bias. Not part of
    /// `UIColorScheme`/`ColorSchemeStore` — it's the fixed default the preview pane starts on
    /// before the user picks a swatch, distinct from the customizable swatches themselves
    /// (`ColorSchemeStore.previewBackgroundPalette`).
    static let editorPreviewBackground = Color(red: 0.18, green: 0.18, blue: 0.18)
}
