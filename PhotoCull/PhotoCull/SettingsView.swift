import SwiftUI

/// The app's Settings window (`Settings { SettingsView() }` in `PhotoCullApp`) — opened via the
/// standard macOS "PhotoCull > Settings…" menu item / Cmd-,. Two panes: editor preferences, and
/// "Appearance" (the live-customizable `ColorSchemeStore` colors — see its own doc comment). Add
/// more `Section`s here (or split further into a `TabView` of panes) as more settings arrive
/// rather than stacking unrelated toggles into `EditorSidebarView` or similar per-feature spots.
struct SettingsView: View {
    @AppStorage(AppSettingsKey.whiteBalanceControlStyle) private var whiteBalanceStyle: WhiteBalanceControlStyle = .classic
    @Environment(ColorSchemeStore.self) private var uiColors

    @State private var isSavingPreset = false
    @State private var newPresetName = ""

    var body: some View {
        Form {
            Section("Editor") {
                Picker("White Balance Control", selection: $whiteBalanceStyle) {
                    ForEach(WhiteBalanceControlStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Appearance") {
                ColorPicker("Sidebar Background", selection: colorBinding(\.sidebarBackground), supportsOpacity: false)
                ColorPicker("Workspace Background", selection: colorBinding(\.workspaceBackground), supportsOpacity: false)
                ColorPicker("Slider/Curve Groove", selection: colorBinding(\.recessedTrackBackground), supportsOpacity: false)
                ColorPicker("Accent Color", selection: colorBinding(\.accentColor), supportsOpacity: false)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview Backgrounds")
                    HStack(spacing: 10) {
                        ForEach(uiColors.previewBackgroundPalette.indices, id: \.self) { i in
                            ColorPicker("", selection: paletteBinding(i), supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }

                HStack {
                    Button("Reset to Default") {
                        uiColors.resetToDefault()
                    }
                    Spacer()
                    Button("Save as Preset…") {
                        newPresetName = ""
                        isSavingPreset = true
                    }
                }
            }

            Section("Color Scheme Presets") {
                if uiColors.presets.isEmpty {
                    Text("No saved presets")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(uiColors.presets) { preset in
                        HStack {
                            Text(preset.name)
                            Spacer()
                            Button("Apply") {
                                uiColors.applyPreset(preset)
                            }
                            Button(role: .destructive) {
                                uiColors.deletePreset(preset)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .alert("Save Color Scheme", isPresented: $isSavingPreset) {
            TextField("Preset Name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                uiColors.saveCurrentAsPreset(name: newPresetName)
            }
        }
    }

    /// A two-way `Binding` into one of `uiColors`' live `Color` properties, persisting the change
    /// (`uiColors.persist()`) on every set — matches this app's existing convention of an explicit
    /// call after a mutation rather than an implicit `didSet` observer (see `ColorSchemeStore
    /// .persist()`'s own doc comment).
    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<ColorSchemeStore, Color>) -> Binding<Color> {
        Binding(
            get: { uiColors[keyPath: keyPath] },
            set: { newValue in
                uiColors[keyPath: keyPath] = newValue
                uiColors.persist()
            }
        )
    }

    /// Same as `colorBinding(_:)`, for one element of `previewBackgroundPalette` — that property is
    /// an array, not a single `Color`, so it needs its own indexed binding rather than a key path.
    private func paletteBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { uiColors.previewBackgroundPalette[index] },
            set: { newValue in
                uiColors.previewBackgroundPalette[index] = newValue
                uiColors.persist()
            }
        )
    }
}
