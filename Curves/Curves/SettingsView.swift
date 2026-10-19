import SwiftUI

/// The app's Settings window (`Settings { SettingsView() }` in `CurvesApp`) — opened via the
/// standard macOS "Curves > Settings…" menu item / Cmd-,.
///
/// Laid out like the main window rather than as a stock grouped `Form`: a vertical list of panes
/// on the left on `sidebarBackground` (same neutral rounded selection pill as `SidebarView`'s
/// rows), and the selected pane on the right on `workspaceBackground`, built from the editor's own
/// flat `section(...)`/`sectionTitle` chrome instead of `Form`'s boxed sections. Add a new pane by
/// adding a `Pane` case and a `@ViewBuilder` for it, not by stacking more rows into an existing one.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case editor, luts, presets, appearance, developer

        var id: Self { self }

        var title: String {
            switch self {
            case .editor: return "Editor"
            case .luts: return "LUTs"
            case .presets: return "Presets"
            case .appearance: return "Appearance"
            case .developer: return "Developer"
            }
        }

        var systemImage: String {
            switch self {
            case .editor: return "slider.horizontal.3"
            case .luts: return "camera.filters"
            case .presets: return "square.stack"
            case .appearance: return "paintpalette"
            case .developer: return "hammer"
            }
        }
    }

    @AppStorage(AppSettingsKey.whiteBalanceControlStyle) private var whiteBalanceStyle: WhiteBalanceControlStyle = .classic
    @AppStorage(AppSettingsKey.developerMode) private var developerMode = false
    @Environment(ColorSchemeStore.self) private var uiColors
    @Environment(LUTLibrary.self) private var lutLibrary
    @Environment(\.openWindow) private var openWindow

    @State private var pane: Pane = .editor
    @State private var isSavingPreset = false
    @State private var newPresetName = ""
    @State private var isChoosingLUTFolder = false
    @State private var isManagingEditPresets = false

    var body: some View {
        HStack(spacing: 0) {
            paneList
            Divider()
            ScrollView {
                paneContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .background(uiColors.workspaceBackground)
        }
        .frame(width: 680, height: 500)
        // Same fixed dark palette as the main window (see `CurvesApp`'s `.preferredColorScheme`
        // comment) — without it this window's AppKit chrome follows the system appearance instead.
        .preferredColorScheme(.dark)
        .tint(uiColors.accentColor)
        .fileImporter(isPresented: $isChoosingLUTFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                lutLibrary.setFolder(url)
            }
        }
        .sheet(isPresented: $isManagingEditPresets) {
            PresetManagerView()
        }
        .alert("Save Color Scheme", isPresented: $isSavingPreset) {
            TextField("Preset Name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                uiColors.saveCurrentAsPreset(name: newPresetName)
            }
        }
    }

    // MARK: - Pane list

    private var paneList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.scoutieSans("ScoutieSans-SemiBold", size: 13, relativeTo: .subheadline))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            ForEach(Pane.allCases) { item in
                paneRow(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .frame(width: 180)
        .frame(maxHeight: .infinity)
        .background(uiColors.sidebarBackground)
    }

    /// Same neutral white pill as `SidebarView.sessionHeader`/`sceneRow` — reads as "selected"
    /// regardless of the user's `accentColor`.
    private func paneRow(_ item: Pane) -> some View {
        let isSelected = pane == item
        return Button {
            pane = item
        } label: {
            Label(item.title, systemImage: item.systemImage)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.white.opacity(0.16) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Panes

    @ViewBuilder
    private var paneContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(pane.title)
                .font(.scoutieSans("ScoutieSans-SemiBold", size: 20, relativeTo: .title2))
            switch pane {
            case .editor: editorPane
            case .luts: lutPane
            case .presets: presetsPane
            case .appearance: appearancePane
            case .developer: developerPane
            }
        }
    }

    private var editorPane: some View {
        section("White Balance Control") {
            Picker("White Balance Control", selection: $whiteBalanceStyle) {
                ForEach(WhiteBalanceControlStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    /// The folder the editor's Film Simulation picker lists `.cube` files from (subfolders
    /// included), plus a checkbox per LUT — unchecking one hides it from the picker without
    /// touching the file. See `LUTLibrary`.
    private var lutPane: some View {
        VStack(alignment: .leading, spacing: 24) {
            section("Folder") {
                HStack(spacing: 8) {
                    Text(lutLibrary.folderURL?.path(percentEncoded: false) ?? "No folder chosen")
                        .font(.callout)
                        .foregroundStyle(lutLibrary.folderURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(lutLibrary.folderURL?.path(percentEncoded: false) ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
                    if lutLibrary.folderURL != nil {
                        Button("Rescan") { lutLibrary.rescan() }
                    }
                    Button("Choose…") { isChoosingLUTFolder = true }
                }
                Text("Every .cube file in this folder and its subfolders appears in the editor's Film Simulation list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if lutLibrary.folderURL != nil {
                section("Show in Editor") {
                    if lutLibrary.entries.isEmpty {
                        Text("No .cube files in this folder")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(lutLibrary.entries) { entry in
                                Toggle(entry.name, isOn: Binding(
                                    get: { !lutLibrary.isHidden(entry) },
                                    set: { lutLibrary.setHidden(!$0, for: entry) }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(uiColors.sidebarBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .onAppear { lutLibrary.rescan() }
    }

    private var presetsPane: some View {
        section("Edit Presets") {
            Text("Global presets, folders, and presets kept within a session — including sessions that have since been deleted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Manage Presets…") { isManagingEditPresets = true }
                .buttonStyle(FilledActionButtonStyle())
                .frame(width: 180)
        }
    }

    private var developerPane: some View {
        section("Developer Mode") {
            Toggle("Developer Mode", isOn: $developerMode)
            Text("Shows in-progress design comparisons in the editor (like the Tone Mapper Styles panel) and unlocks the Component Gallery — every custom control in the app on one page, for future design work.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openWindow(id: ComponentGalleryView.windowID)
            } label: {
                Label("Open Component Gallery", systemImage: "square.grid.2x2")
            }
            .disabled(!developerMode)
        }
    }

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 24) {
            section("Colors") {
                VStack(alignment: .leading, spacing: 8) {
                    colorRow("Sidebar Background", \.sidebarBackground)
                    colorRow("Workspace Background", \.workspaceBackground)
                    colorRow("Slider/Curve Groove", \.recessedTrackBackground)
                    colorRow("Accent Color", \.accentColor)
                }
            }

            section("Preview Backgrounds") {
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

            section("Color Scheme Presets") {
                if uiColors.presets.isEmpty {
                    Text("No saved presets")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
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
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(uiColors.sidebarBackground, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func colorRow(_ title: String, _ keyPath: ReferenceWritableKeyPath<ColorSchemeStore, Color>) -> some View {
        HStack {
            Text(title)
                .font(.callout)
            Spacer()
            ColorPicker(title, selection: colorBinding(keyPath), supportsOpacity: false)
                .labelsHidden()
        }
        .frame(maxWidth: 320)
    }

    // MARK: - Bindings

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
