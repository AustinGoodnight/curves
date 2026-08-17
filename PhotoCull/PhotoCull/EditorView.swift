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
            sharpnessAmount: asset.editSharpnessAmount,
            filmicRGB: filmicParams,
            colorBalanceRGB: colorBalanceParams
        )
    }

    private var filmicParams: FilmicRGBParameters? {
        guard asset.editFilmicEnabled else { return nil }
        let d = FilmicRGBParameters.darktableDefault
        return FilmicRGBParameters(
            blackPointSource: asset.editFilmicBlackPointSource ?? d.blackPointSource,
            whitePointSource: asset.editFilmicWhitePointSource ?? d.whitePointSource,
            latitude: asset.editFilmicLatitude ?? d.latitude,
            contrast: asset.editFilmicContrast ?? d.contrast,
            saturation: asset.editFilmicSaturation ?? d.saturation,
            balance: asset.editFilmicBalance ?? d.balance
        )
    }

    private var colorBalanceParams: ColorBalanceRGBParameters? {
        guard asset.editColorBalanceEnabled else { return nil }
        let d = ColorBalanceRGBParameters.darktableDefault
        return ColorBalanceRGBParameters(
            shadowsY: asset.editColorBalanceShadowsY ?? d.shadowsY,
            shadowsC: asset.editColorBalanceShadowsC ?? d.shadowsC,
            shadowsH: asset.editColorBalanceShadowsH ?? d.shadowsH,
            midtonesY: asset.editColorBalanceMidtonesY ?? d.midtonesY,
            midtonesC: asset.editColorBalanceMidtonesC ?? d.midtonesC,
            midtonesH: asset.editColorBalanceMidtonesH ?? d.midtonesH,
            highlightsY: asset.editColorBalanceHighlightsY ?? d.highlightsY,
            highlightsC: asset.editColorBalanceHighlightsC ?? d.highlightsC,
            highlightsH: asset.editColorBalanceHighlightsH ?? d.highlightsH,
            globalY: asset.editColorBalanceGlobalY ?? d.globalY,
            globalC: asset.editColorBalanceGlobalC ?? d.globalC,
            globalH: asset.editColorBalanceGlobalH ?? d.globalH,
            chromaGlobal: asset.editColorBalanceChromaGlobal ?? d.chromaGlobal,
            vibrance: asset.editColorBalanceVibrance ?? d.vibrance,
            contrast: asset.editColorBalanceContrast ?? d.contrast
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
                Section("Filmic RGB") {
                    Toggle("Enable", isOn: Binding(
                        get: { asset.editFilmicEnabled },
                        set: { asset.editFilmicEnabled = $0; scheduleRender() }
                    ))
                    if asset.editFilmicEnabled {
                        let d = FilmicRGBParameters.darktableDefault
                        slider(
                            "White EV", value: bind(\.editFilmicWhitePointSource, fallback: d.whitePointSource),
                            range: 2...8
                        )
                        slider(
                            "Black EV", value: bind(\.editFilmicBlackPointSource, fallback: d.blackPointSource),
                            range: -14 ... -2
                        )
                        slider(
                            "Contrast", value: bind(\.editFilmicContrast, fallback: d.contrast),
                            range: 0.5...2
                        )
                        slider(
                            "Latitude", value: bind(\.editFilmicLatitude, fallback: d.latitude),
                            range: 0.01...80
                        )
                        slider(
                            "Saturation", value: bind(\.editFilmicSaturation, fallback: d.saturation),
                            range: -100...100
                        )
                        slider(
                            "Balance", value: bind(\.editFilmicBalance, fallback: d.balance),
                            range: -50...50
                        )
                    }
                }
                Section("Color Balance RGB") {
                    Toggle("Enable", isOn: Binding(
                        get: { asset.editColorBalanceEnabled },
                        set: { asset.editColorBalanceEnabled = $0; scheduleRender() }
                    ))
                    if asset.editColorBalanceEnabled {
                        wheel(
                            "Global",
                            y: \.editColorBalanceGlobalY, c: \.editColorBalanceGlobalC, h: \.editColorBalanceGlobalH
                        )
                        wheel(
                            "Shadows",
                            y: \.editColorBalanceShadowsY, c: \.editColorBalanceShadowsC, h: \.editColorBalanceShadowsH
                        )
                        wheel(
                            "Midtones",
                            y: \.editColorBalanceMidtonesY, c: \.editColorBalanceMidtonesC, h: \.editColorBalanceMidtonesH
                        )
                        wheel(
                            "Highlights",
                            y: \.editColorBalanceHighlightsY, c: \.editColorBalanceHighlightsC, h: \.editColorBalanceHighlightsH
                        )
                        slider(
                            "Chroma", value: bind(\.editColorBalanceChromaGlobal, fallback: 0),
                            range: -1...1
                        )
                        slider(
                            "Vibrance", value: bind(\.editColorBalanceVibrance, fallback: 0),
                            range: -1...1
                        )
                        slider(
                            "Contrast", value: bind(\.editColorBalanceContrast, fallback: 0),
                            range: -1...1
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
            || asset.editSharpnessAmount != nil || asset.editFilmicEnabled
            || asset.editColorBalanceEnabled
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

    @ViewBuilder
    private func wheel(
        _ title: String,
        y: ReferenceWritableKeyPath<PhotoAsset, Double?>,
        c: ReferenceWritableKeyPath<PhotoAsset, Double?>,
        h: ReferenceWritableKeyPath<PhotoAsset, Double?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            slider("Luminance", value: bind(y, fallback: 0), range: -1...1)
            slider("Chroma", value: bind(c, fallback: 0), range: 0...1)
            slider("Hue", value: bind(h, fallback: 0), range: 0...360)
        }
        .padding(.vertical, 2)
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
        asset.editFilmicEnabled = false
        asset.editFilmicWhitePointSource = nil
        asset.editFilmicBlackPointSource = nil
        asset.editFilmicContrast = nil
        asset.editFilmicLatitude = nil
        asset.editFilmicSaturation = nil
        asset.editFilmicBalance = nil
        asset.editColorBalanceEnabled = false
        asset.editColorBalanceGlobalY = nil
        asset.editColorBalanceGlobalC = nil
        asset.editColorBalanceGlobalH = nil
        asset.editColorBalanceShadowsY = nil
        asset.editColorBalanceShadowsC = nil
        asset.editColorBalanceShadowsH = nil
        asset.editColorBalanceMidtonesY = nil
        asset.editColorBalanceMidtonesC = nil
        asset.editColorBalanceMidtonesH = nil
        asset.editColorBalanceHighlightsY = nil
        asset.editColorBalanceHighlightsC = nil
        asset.editColorBalanceHighlightsH = nil
        asset.editColorBalanceContrast = nil
        asset.editColorBalanceVibrance = nil
        asset.editColorBalanceChromaGlobal = nil
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
