import SwiftUI
import SwiftData
import PhotoCatalog

/// "Manage Presets…" in `ExportBarView`'s preset menu — lists the user's own saved `ExportPreset`s
/// (built-ins never appear here; they're not stored rows) with swipe/`onDelete` removal, plus an
/// always-visible "New Preset" form below for adding another. A genuine separate `View` type, same
/// isolation reasoning as `PresetBrowserView`: this is the one place with its own `@Query`, so
/// saving/deleting an `ExportPreset` only re-invokes this sheet's `body`, not `ExportBarView`'s.
struct ExportPresetManagerSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ExportPreset.sortIndex) private var presets: [ExportPreset]

    @State private var newName = ""
    @State private var newFormat: ExportImageFormat = .jpeg
    @State private var newQuality: Double = 0.9
    @State private var resizeEnabled = false
    @State private var newMaxLongEdge: Double = 2048

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Presets")
                .font(.headline)

            if presets.isEmpty {
                Text("No custom presets saved yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(presets) { preset in
                        HStack {
                            Text(preset.name)
                            Spacer()
                            Text(summary(for: preset))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { modelContext.delete(presets[index]) }
                    }
                }
                .frame(minHeight: 100, maxHeight: 200)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("New Preset")
                    .font(.subheadline.weight(.semibold))
                TextField("Name", text: $newName)
                Picker("Format", selection: $newFormat) {
                    Text("JPEG").tag(ExportImageFormat.jpeg)
                    Text("TIFF").tag(ExportImageFormat.tiff)
                    Text("PNG").tag(ExportImageFormat.png)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if newFormat == .jpeg {
                    HStack {
                        Text("Quality")
                        Slider(value: $newQuality, in: 0.5...1)
                        Text("\(Int((newQuality * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Resize to Max Dimension", isOn: $resizeEnabled)
                if resizeEnabled {
                    HStack {
                        Text("Long Edge")
                        TextField("Pixels", value: $newMaxLongEdge, format: .number)
                            .frame(width: 80)
                        Text("px")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                Button("Save Preset") { savePreset() }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func summary(for preset: ExportPreset) -> String {
        var parts: [String]
        switch preset.format {
        case .jpeg: parts = ["JPG \(Int((preset.quality * 100).rounded()))%"]
        case .tiff: parts = ["TIFF"]
        case .png: parts = ["PNG"]
        }
        if let maxLongEdge = preset.maxLongEdge {
            parts.append("\(Int(maxLongEdge))px")
        }
        return parts.joined(separator: " · ")
    }

    private func savePreset() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = ExportPreset(
            name: trimmed,
            format: newFormat,
            quality: newQuality,
            maxLongEdge: resizeEnabled ? newMaxLongEdge : nil,
            sortIndex: presets.count
        )
        modelContext.insert(preset)
        newName = ""
        resizeEnabled = false
        newQuality = 0.9
        newFormat = .jpeg
    }
}
