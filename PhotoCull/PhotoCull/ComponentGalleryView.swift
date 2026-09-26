import SwiftUI
import RawEngine

/// Developer Mode's "Component Gallery" window (Settings > Developer > Open Component Gallery) —
/// every custom control and piece of chrome the app has built, laid out on one scrollable page
/// with live, local sample state, so designs can be compared side by side without hunting for
/// where each one lives in the real UI (or needing a photo open to see it at all).
///
/// Everything here is bound to throwaway `@State` (and a private `DetailStore` for the grid
/// toolbar controls), never to a real `PhotoAsset`/`Stage`, so nothing done in this window touches
/// the library. When adding a new custom control elsewhere, add a sample of it here too.
struct ComponentGalleryView: View {
    static let windowID = "componentGallery"

    @Environment(ColorSchemeStore.self) private var uiColors

    // Tone mapper
    @State private var toneMapper: ToneMapper = .filmic

    // Horizontal sliders
    @State private var sliderValue = 0.25

    // Vertical faders
    @State private var temperatureFader = 0.5
    @State private var tintFader = 0.4
    @State private var intensityFader = 0.6
    @State private var circleFader = 0.35
    @State private var circleDiamondFader = 0.7

    // Knobs
    @State private var knobUnit = 0.65
    @State private var knobBipolar = 0.15

    // Toggles
    @State private var stoplightOn = true
    @State private var stoplightOff = false

    // Color wheel
    @State private var wheelHue = 210.0
    @State private var wheelChroma = 0.2
    @State private var wheelLuminance = 0.0

    // XY white balance
    @State private var xyTemperature = 5500.0
    @State private var xyTint = 0.0

    // Curves
    @State private var rgbCurvePoints: [SIMD2<Double>] = [[0, 0], [0.25, 0.18], [0.75, 0.84], [1, 1]]
    @State private var hueCurvePoints: [SIMD2<Double>] = ColorZonesParameters.identityPoints

    // Grid toolbar controls
    @State private var store = DetailStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("Component Gallery")
                    .font(.scoutieSans("ScoutieSans-SemiBold", size: 22, relativeTo: .title2))
                Text("Every custom control in the app, with local sample values — nothing here touches your library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                gallerySection("Slider Experiments", file: "ExperimentalControls.swift") {
                    ExperimentalControlsGallery()
                }
                toneMapperSection
                slidersSection
                fadersSection
                knobsSection
                togglesSection
                colorSection
                curvesSection
                dataViewsSection
                toolbarControlsSection
                chromeSection
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(uiColors.workspaceBackground)
        .frame(minWidth: 760, minHeight: 600)
        .preferredColorScheme(.dark)
        .tint(uiColors.accentColor)
    }

    // MARK: - Sections

    private var toneMapperSection: some View {
        gallerySection("Tone Mapper Styles", file: "ToneMapperPickerStyles.swift") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], alignment: .leading, spacing: 24) {
                specimen("1 · Sliding Pill") { ToneMapperSlidingPill(selection: $toneMapper) }
                specimen("2 · Curve Tiles") { ToneMapperCurveTiles(selection: $toneMapper) }
                specimen("3 · Rolloff Strips") { ToneMapperRolloffStrips(selection: $toneMapper) }
                specimen("4 · Underline Tabs") { ToneMapperUnderlineTabs(selection: $toneMapper) }
                specimen("5 · Stoplight Dots") { ToneMapperStoplightDots(selection: $toneMapper) }
                specimen("6 · Curve Carousel") { ToneMapperCurveCarousel(selection: $toneMapper) }
                specimen("Current · Segmented Picker") {
                    Picker("Tone Mapper", selection: $toneMapper) {
                        ForEach(ToneMapper.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                    .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var slidersSection: some View {
        gallerySection("Horizontal Sliders", file: "MinimalSlider.swift · EditorControls.swift slider(...)") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], alignment: .leading, spacing: 20) {
                specimen("Capsule · Circle (default)") {
                    slider("Value", value: $sliderValue, range: -1...1, resetValue: 0, ticks: [-1, -0.5, 0, 0.5, 1])
                }
                specimen("Capsule · Diamond") {
                    slider("Value", value: $sliderValue, range: -1...1, resetValue: 0, ticks: [-1, -0.5, 0, 0.5, 1], thumbShape: .diamond)
                }
                specimen("Hairline · Circle") {
                    slider("Value", value: $sliderValue, range: -1...1, resetValue: 0, ticks: [-1, -0.5, 0, 0.5, 1], trackStyle: .hairline)
                }
                specimen("Hairline · Diamond (Exposure/Contrast)") {
                    slider(
                        "Value", value: $sliderValue, range: -1...1, resetValue: 0, ticks: [-1, -0.5, 0, 0.5, 1],
                        trackStyle: .hairline, thumbShape: .diamond
                    )
                }
                specimen("In a recessed box (sidebar)") {
                    VStack(spacing: 10) {
                        slider("Exposure", value: $sliderValue, range: -1...1, resetValue: 0, ticks: [-1, 0, 1], trackStyle: .hairline, thumbShape: .diamond)
                        slider("Contrast", value: $sliderValue, range: -1...1, resetValue: 0, ticks: [-1, 0, 1], trackStyle: .hairline, thumbShape: .diamond)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var fadersSection: some View {
        gallerySection("Vertical Faders", file: "VerticalGradientSlider.swift · VerticalCircleSlider.swift") {
            HStack(alignment: .top, spacing: 26) {
                verticalGradientSlider("Temp", value: $temperatureFader, range: 0...1, gradient: .neutralTemperature, valueText: "5500")
                verticalGradientSlider("Tint", value: $tintFader, range: 0...1, gradient: .neutralTint, valueText: "+4")
                verticalGradientSlider("Chr", value: $intensityFader, range: 0...1, gradient: .colorIntensity, valueText: "", diamondThumb: true)
                verticalCircleSlider("Circle", value: $circleFader, range: 0...1, valueText: "")
                verticalCircleSlider("Diamond", value: $circleDiamondFader, range: 0...1, valueText: "", diamondThumb: true)
            }
        }
    }

    private var knobsSection: some View {
        gallerySection("Knobs", file: "KnobControl.swift") {
            HStack(alignment: .top, spacing: 40) {
                specimen("Sizes") {
                    HStack(alignment: .center, spacing: 16) {
                        KnobControl(value: $knobUnit, range: 0...1, resetValue: 0, diameter: 36)
                        KnobControl(value: $knobUnit, range: 0...1, resetValue: 0)
                        KnobControl(value: $knobUnit, range: 0...1, resetValue: 0, diameter: 72)
                    }
                }
                specimen("Value beside (LUT Intensity)") {
                    HStack(spacing: 8) {
                        KnobControl(value: $knobUnit, range: 0...1, resetValue: 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Intensity").font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.0f%%", knobUnit * 100)).font(.caption.monospacedDigit())
                        }
                    }
                }
                specimen("Value below") {
                    VStack(spacing: 6) {
                        KnobControl(value: $knobUnit, range: 0...1, resetValue: 0)
                        VStack(spacing: 2) {
                            Text("Dehaze").font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.0f%%", knobUnit * 100)).font(.caption.monospacedDigit())
                        }
                    }
                }
                specimen("Value inside (sidebar)") {
                    VStack(spacing: 6) {
                        KnobControl(value: $knobBipolar, range: -0.5...0.5, resetValue: 0)
                            .overlay {
                                Text(signed(knobBipolar * 200))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .allowsHitTesting(false)
                            }
                        Text("Chroma").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var togglesSection: some View {
        gallerySection("Toggles", file: "StoplightToggle.swift") {
            HStack(spacing: 24) {
                specimen("On") { StoplightToggle(isOn: $stoplightOn) }
                specimen("Off") { StoplightToggle(isOn: $stoplightOff) }
                specimen("Large") { StoplightToggle(isOn: $stoplightOn, diameter: 16) }
                specimen("Section title + toggle") {
                    HStack(spacing: 4) {
                        sectionTitle("Curve", enabled: $stoplightOn)
                        resetButton(disabled: false, action: {})
                        StoplightToggle(isOn: $stoplightOn)
                    }
                }
            }
        }
    }

    private var colorSection: some View {
        gallerySection("Color Controls", file: "ColorWheelControl.swift · XYWhiteBalanceControl.swift") {
            HStack(alignment: .top, spacing: 40) {
                specimen("Color Wheel") {
                    ColorWheelControl(
                        title: "Shadows", hue: $wheelHue, chroma: $wheelChroma, luminance: $wheelLuminance,
                        maxChroma: 0.5, luminanceRange: -1...1
                    )
                }
                specimen("XY White Balance") {
                    XYWhiteBalanceControl(
                        temperature: $xyTemperature, tint: $xyTint,
                        temperatureRange: 2000...12000, tintRange: -150...150,
                        defaultTemperature: 5500, defaultTint: 0
                    )
                }
            }
        }
    }

    private var curvesSection: some View {
        gallerySection("Curve Editors", file: "CurveEditorControl.swift") {
            HStack(alignment: .top, spacing: 24) {
                specimen("RGB Curve (with histogram)") {
                    CurveEditorControl(
                        points: $rgbCurvePoints, height: 200, histogram: Self.sampleLuminanceHistogram,
                        showHeader: false, showEndpointControls: true
                    )
                    .frame(width: 280)
                }
                specimen("Color Zones (hue axis)") {
                    CurveEditorControl(
                        points: $hueCurvePoints, height: 200,
                        identityPoints: ColorZonesParameters.identityPoints,
                        maxPoints: ColorZonesKernel.maxNodes, splineType: .catmullRom, referenceIsFlat: true,
                        showHueAxis: true, showHeader: false, lineColor: .white, showGrid: true
                    )
                    .frame(width: 320)
                }
            }
        }
    }

    private var dataViewsSection: some View {
        gallerySection("Data Views", file: "RGBHistogramView.swift · ColorDensityWheel.swift") {
            HStack(alignment: .top, spacing: 24) {
                specimen("RGB Histogram") {
                    RGBHistogramView(data: Self.sampleRGBHistogram, height: 140)
                        .frame(width: 320)
                }
                specimen("Color Density Wheel") {
                    ColorDensityWheel(density: Self.sampleDensity, diameter: 140)
                }
            }
        }
    }

    private var toolbarControlsSection: some View {
        gallerySection("Grid Toolbar Controls", file: "DetailPaneView.swift") {
            VStack(alignment: .leading, spacing: 16) {
                specimen("Grid Zoom") { GridZoomControl(store: store) }
                specimen("Rating Filter") { RatingFilterControl(store: store) }
                specimen("Flag Filter") { FlagFilterControl(store: store) }
                specimen("File Type Filter") { FileTypeFilterControl(store: store) }
                specimen("Mode Switcher") { ModeSwitcherControl(store: store) }
            }
        }
    }

    private var chromeSection: some View {
        gallerySection("Chrome & Colors", file: "ColorSchemeStore.swift · EditorControls.swift") {
            HStack(alignment: .top, spacing: 24) {
                specimen("Recessed box") {
                    Text("Content")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 140, height: 50)
                        .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
                }
                specimen("Selection pill") {
                    Text("Selected Row")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(width: 160, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.16)))
                }
                specimen("Palette") {
                    HStack(spacing: 6) {
                        swatch(uiColors.sidebarBackground, "Sidebar")
                        swatch(uiColors.workspaceBackground, "Workspace")
                        swatch(uiColors.recessedTrackBackground, "Recessed")
                        swatch(uiColors.accentColor, "Accent")
                    }
                }
            }
        }
    }

    // MARK: - Building blocks

    private func gallerySection<Content: View>(_ title: String, file: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.scoutieSans("ScoutieSans-SemiBold", size: 15, relativeTo: .headline))
                Text(file)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            content()
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(uiColors.sidebarBackground, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func specimen<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func swatch(_ color: Color, _ name: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .frame(width: 44, height: 44)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func signed(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    // MARK: - Sample data

    private static let sampleLuminanceHistogram: [Float] = (0..<64).map { i in
        let x = Float(i) / 63
        return max(0.05, exp(-pow((x - 0.4) / 0.18, 2)) + 0.5 * exp(-pow((x - 0.8) / 0.08, 2)))
    }

    private static let sampleRGBHistogram: RGBHistogramData = {
        func channel(peak: Float, width: Float) -> [Float] {
            (0..<128).map { i in
                let x = Float(i) / 127
                return exp(-pow((x - peak) / width, 2))
            }
        }
        return RGBHistogramData(r: channel(peak: 0.55, width: 0.2), g: channel(peak: 0.45, width: 0.22), b: channel(peak: 0.35, width: 0.18))
    }()

    private static let sampleDensity: [Float] = (0..<48).flatMap { h -> [Float] in
        let hueWeight = Float(0.3 + 0.7 * max(0, cos(Double(h) / 48 * 2 * .pi - 0.6)))
        return (0..<12).map { c in hueWeight * Float(exp(-Double(c) / 4)) }
    }
}
