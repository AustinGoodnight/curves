import SwiftUI

/// Live, user-customizable UI chrome colors — the sidebar/workspace backgrounds, the slider/curve
/// "recessed groove" color, the app's own accent color (independent of the system Accent Color
/// preference), and the 6 selectable swatches in `EditorView`'s preview-background palette.
/// Injected once at the app root (`PhotoCullApp`) via `.environment(_:)` and read from wherever one
/// of those colors used to be a fixed `Color+Workspace.swift` constant. Swift's Observation
/// framework scopes invalidation to whichever specific stored property a view's `body` actually
/// reads, so a view reading only `colorScheme.accentColor` doesn't re-render when
/// `previewBackgroundPalette` changes elsewhere — same fine-grained tracking `DetailStore` relies
/// on for the same reason (see its own doc comment).
@Observable
final class ColorSchemeStore {
    var sidebarBackground: Color
    var workspaceBackground: Color
    var recessedTrackBackground: Color
    var accentColor: Color
    /// Always exactly 6 — see `UIColorScheme.previewBackgroundPalette`'s doc comment.
    var previewBackgroundPalette: [Color]

    private(set) var presets: [NamedColorScheme]

    private static let schemeKey = "uiColorScheme"
    private static let presetsKey = "uiColorSchemePresets"

    init() {
        let scheme = Self.loadScheme() ?? .default
        sidebarBackground = scheme.sidebarBackground.color
        workspaceBackground = scheme.workspaceBackground.color
        recessedTrackBackground = scheme.recessedTrackBackground.color
        accentColor = scheme.accentColor.color
        previewBackgroundPalette = scheme.previewBackgroundPalette.map(\.color)
        presets = Self.loadPresets()
    }

    private var currentScheme: UIColorScheme {
        UIColorScheme(
            sidebarBackground: RGBAColor(sidebarBackground),
            workspaceBackground: RGBAColor(workspaceBackground),
            recessedTrackBackground: RGBAColor(recessedTrackBackground),
            accentColor: RGBAColor(accentColor),
            previewBackgroundPalette: previewBackgroundPalette.map(RGBAColor.init)
        )
    }

    /// Call after directly mutating one of the live `Color` properties above (every `ColorPicker`
    /// binding in `SettingsView` does) so the change survives a relaunch. Not automatic (no
    /// `didSet` observer) — matches this app's existing convention of an explicit call after a
    /// mutation (`scheduleRender`, `syncModuleEnabled`, …) rather than an implicit hook.
    func persist() {
        guard let data = try? JSONEncoder().encode(currentScheme) else { return }
        UserDefaults.standard.set(data, forKey: Self.schemeKey)
    }

    private static func loadScheme() -> UIColorScheme? {
        guard let data = UserDefaults.standard.data(forKey: schemeKey) else { return nil }
        return try? JSONDecoder().decode(UIColorScheme.self, from: data)
    }

    private static func loadPresets() -> [NamedColorScheme] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let decoded = try? JSONDecoder().decode([NamedColorScheme].self, from: data) else { return [] }
        return decoded
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.presetsKey)
    }

    func resetToDefault() {
        apply(.default)
    }

    func saveCurrentAsPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presets.append(NamedColorScheme(name: trimmed, scheme: currentScheme))
        persistPresets()
    }

    func applyPreset(_ preset: NamedColorScheme) {
        apply(preset.scheme)
    }

    func deletePreset(_ preset: NamedColorScheme) {
        presets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    private func apply(_ scheme: UIColorScheme) {
        sidebarBackground = scheme.sidebarBackground.color
        workspaceBackground = scheme.workspaceBackground.color
        recessedTrackBackground = scheme.recessedTrackBackground.color
        accentColor = scheme.accentColor.color
        previewBackgroundPalette = scheme.previewBackgroundPalette.map(\.color)
        persist()
    }
}
