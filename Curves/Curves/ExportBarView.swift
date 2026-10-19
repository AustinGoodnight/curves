import SwiftUI
import SwiftData
import AppKit
import PhotoCatalog

/// The culling grid's bottom export bar — pick a preset, then export either the current selection
/// or everything currently visible in the grid (`store.filteredAssets`, i.e. respecting whatever
/// scene/session/rating/flag filter is active). A genuine separate `View` type (not inline in
/// `GridPane.body`), same isolation reasoning as `RatingFilterControl` in
/// `DetailPaneView.swift`: this is the one piece of the grid pane that reads `store.selection`/
/// `store.filteredAssets` as *values* for its own button labels/enabled state, so only this small
/// view's `body` re-runs when those change, not the whole `GridPane`.
///
/// "Export Selection"/"Export All" use `FilledActionButtonStyle`, a shared filled-box "primary
/// action" look.
struct ExportBarView: View {
    @Bindable var store: DetailStore
    @Query(sort: \ExportPreset.sortIndex) private var customPresets: [ExportPreset]
    @Environment(ColorSchemeStore.self) private var uiColors

    @State private var selectedSettings: ExportSettings = BuiltInExportPresets.all[0]
    @State private var isShowingPresetManager = false
    @State private var pendingScope: ExportScope?
    @State private var isExporting = false
    @State private var exportProgress: (completed: Int, total: Int)?
    @State private var exportResultMessage: String?

    private var allPresets: [ExportSettings] {
        BuiltInExportPresets.all + customPresets.map(\.settings)
    }

    var body: some View {
        HStack(spacing: 16) {
            presetMenu

            Spacer()

            if let exportProgress {
                ProgressView(value: Double(exportProgress.completed), total: Double(exportProgress.total))
                    .frame(width: 140)
                Text("\(exportProgress.completed) of \(exportProgress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Export Selection") { pendingScope = .selection }
                    .buttonStyle(FilledActionButtonStyle(isEnabled: !store.selection.isEmpty))
                    .disabled(store.selection.isEmpty)
                    .frame(width: 160)

                Button("Export All") { pendingScope = .all }
                    .buttonStyle(FilledActionButtonStyle(isEnabled: !store.filteredAssets.isEmpty))
                    .disabled(store.filteredAssets.isEmpty)
                    .frame(width: 120)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(uiColors.sidebarBackground)
        .sheet(item: $pendingScope) { scope in
            ExportDestinationSheet(
                scope: scope,
                assetCount: assets(for: scope).count,
                presetName: selectedSettings.name,
                onConfirm: { destination in beginExport(scope: scope, destination: destination) }
            )
        }
        .sheet(isPresented: $isShowingPresetManager) {
            ExportPresetManagerSheet()
        }
        .alert("Export", isPresented: Binding(
            get: { exportResultMessage != nil },
            set: { if !$0 { exportResultMessage = nil } }
        )) {
            Button("OK") { exportResultMessage = nil }
        } message: {
            Text(exportResultMessage ?? "")
        }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(allPresets) { settings in
                Button {
                    selectedSettings = settings
                } label: {
                    if settings.name == selectedSettings.name {
                        Label(settings.name, systemImage: "checkmark")
                    } else {
                        Text(settings.name)
                    }
                }
            }
            Divider()
            Button("Manage Presets…") { isShowingPresetManager = true }
        } label: {
            Label(selectedSettings.name, systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func assets(for scope: ExportScope) -> [PhotoAsset] {
        switch scope {
        case .selection:
            return store.filteredAssets.filter { store.selection.contains($0.id) }
        case .all:
            return store.filteredAssets
        }
    }

    private func beginExport(scope: ExportScope, destination: ExportDestination) {
        let assets = assets(for: scope)
        guard !assets.isEmpty else { return }
        let settings = selectedSettings
        exportProgress = (0, assets.count)
        Task {
            let result = await performBatchExport(assets: assets, settings: settings, destination: destination) { completed, total in
                exportProgress = (completed, total)
            }
            exportProgress = nil
            exportResultMessage = result.failed == 0
                ? "Exported \(result.succeeded) photo\(result.succeeded == 1 ? "" : "s")."
                : "Exported \(result.succeeded), failed \(result.failed)."
        }
    }
}

/// Presented as a sheet from `ExportBarView` once "Export Selection"/"Export All" is tapped — pick
/// where the batch lands, either an arbitrary folder or nested inside each photo's own source
/// folder — then confirm. Kept separate from the count/photo list itself: this only decides the
/// destination, `performBatchExport` (started by `ExportBarView.beginExport`) does the actual work.
private struct ExportDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let scope: ExportScope
    let assetCount: Int
    let presetName: String
    var onConfirm: (ExportDestination) -> Void

    @State private var mode: DestinationMode = .nestedInSession
    @State private var chosenFolder: URL?
    @State private var subfolderName = "Export"

    private enum DestinationMode: String, CaseIterable, Identifiable {
        case chooseFolder = "Choose Folder"
        case nestedInSession = "Inside Session Folder"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export \(assetCount) Photo\(assetCount == 1 ? "" : "s")")
                    .font(.headline)
                Text("Preset: \(presetName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker("Destination", selection: $mode) {
                ForEach(DestinationMode.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            switch mode {
            case .chooseFolder:
                HStack {
                    Text(chosenFolder?.path ?? "No folder selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(chosenFolder == nil ? Color.secondary : Color.primary)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
            case .nestedInSession:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Folder Name")
                        TextField("Export", text: $subfolderName)
                    }
                    Text("Saves next to each photo's original file, inside a “\(subfolderName.isEmpty ? "Export" : subfolderName)” subfolder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == .chooseFolder && chosenFolder == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        chosenFolder = panel.url
    }

    private func confirm() {
        switch mode {
        case .chooseFolder:
            guard let chosenFolder else { return }
            onConfirm(.folder(chosenFolder))
        case .nestedInSession:
            let trimmed = subfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            onConfirm(.nestedInSourceFolder(name: trimmed.isEmpty ? "Export" : trimmed))
        }
        dismiss()
    }
}
