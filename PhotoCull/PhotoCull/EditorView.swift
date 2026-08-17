import SwiftUI
import AppKit
import SwiftData
import PhotoCatalog
import RawEngine

struct EditorView: View {
    @Bindable var asset: PhotoAsset
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var renderer = RawImageRenderer()

    @State private var previewImage: CGImage?
    @State private var isReady = false
    @State private var renderGeneration = 0
    @State private var exportStatus: String?

    private var params: RawEditParameters {
        RawEditParameters(
            exposure: asset.editExposure,
            boostAmount: asset.editBoostAmount,
            neutralTemperature: asset.editNeutralTemperature,
            neutralTint: asset.editNeutralTint,
            sharpnessAmount: asset.editSharpnessAmount
        )
    }

    var body: some View {
        HSplitView {
            ZStack {
                Color.black
                if let previewImage {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else {
                    ProgressView("Decoding RAW…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .frame(minWidth: 480, minHeight: 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Form {
                Section("Exposure") {
                    slider(
                        "Exposure", value: bind(\.editExposure, fallback: renderer.defaultExposure),
                        range: -4...4
                    )
                    slider(
                        "Boost", value: bind(\.editBoostAmount, fallback: renderer.defaultBoostAmount),
                        range: 0...1
                    )
                }
                Section("White Balance") {
                    slider(
                        "Temperature", value: bind(\.editNeutralTemperature, fallback: renderer.defaultNeutralTemperature),
                        range: 2000...12000
                    )
                    slider(
                        "Tint", value: bind(\.editNeutralTint, fallback: renderer.defaultNeutralTint),
                        range: -150...150
                    )
                }
                if isReady && renderer.isSharpnessSupported {
                    Section("Detail") {
                        slider(
                            "Sharpness", value: bind(\.editSharpnessAmount, fallback: renderer.defaultSharpnessAmount),
                            range: 0...1
                        )
                    }
                }
                Section {
                    Button("Reset All") { resetAll() }
                        .disabled(!hasEdits)
                    Button("Export…") { exportImage() }
                        .disabled(!isReady)
                }
            }
            .formStyle(.grouped)
            .disabled(!isReady)
            .frame(width: 280)
        }
        .navigationTitle(asset.fileName)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    try? modelContext.save()
                    dismiss()
                }
            }
        }
        .task(id: asset.filePath) {
            await loadAndRender()
        }
        .alert("Export", isPresented: Binding(
            get: { exportStatus != nil },
            set: { if !$0 { exportStatus = nil } }
        )) {
            Button("OK") { exportStatus = nil }
        } message: {
            Text(exportStatus ?? "")
        }
    }

    private var hasEdits: Bool {
        asset.editExposure != nil || asset.editBoostAmount != nil
            || asset.editNeutralTemperature != nil || asset.editNeutralTint != nil
            || asset.editSharpnessAmount != nil
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<PhotoAsset, Double?>, fallback: Double) -> Binding<Double> {
        Binding(
            get: { asset[keyPath: keyPath] ?? fallback },
            set: { newValue in
                asset[keyPath: keyPath] = newValue
                scheduleRender()
            }
        )
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    private func loadAndRender() async {
        let url = asset.resolvedURL()
        let currentParams = params
        let (loaded, image) = await Task.detached(priority: .userInitiated) { () -> (Bool, CGImage?) in
            let loaded = renderer.load(url: url)
            guard loaded else { return (false, nil) }
            return (true, renderer.renderPreview(params: currentParams, maxPixelSize: 1600))
        }.value
        isReady = loaded
        previewImage = image
    }

    private func scheduleRender() {
        renderGeneration += 1
        let generation = renderGeneration
        let currentParams = params
        Task {
            try? await Task.sleep(nanoseconds: 12_000_000)
            guard generation == renderGeneration else { return }
            let image = renderer.renderPreview(params: currentParams, maxPixelSize: 1600)
            guard generation == renderGeneration else { return }
            previewImage = image
        }
    }

    private func resetAll() {
        asset.editExposure = nil
        asset.editBoostAmount = nil
        asset.editNeutralTemperature = nil
        asset.editNeutralTint = nil
        asset.editSharpnessAmount = nil
        scheduleRender()
    }

    private func exportImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .tiff]
        panel.nameFieldStringValue = (asset.fileName as NSString).deletingPathExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let format: ExportFormat = url.pathExtension.lowercased() == "tiff" ? .tiff : .jpeg(quality: 0.9)
        do {
            try ExportPipeline.export(renderer: renderer, params: params, format: format, to: url)
            exportStatus = "Exported to \(url.lastPathComponent)."
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }
}
