import SwiftUI
import RawEngine

/// The six RGB Curve editor concepts compared in `EditorSidebarView`'s Developer Mode "Curve Editor
/// Styles" panel — each a different mental model for the same curve, all built from the shared
/// pieces in `CurveComponents.swift`. The real editor (`CurveWorkbench`) combines the winners:
/// Targeted Drag (swappable to Refined Points), the Zone Grid's labelling, the Ramp Preview, and
/// Presets behind a header button.

// MARK: - 1. Region Sliders

/// Lightroom's parametric model: four bipolar sliders — Shadows, Darks, Lights, Highlights — each
/// lifting or lowering one quarter of the tonal range; the curve is derived from them (always
/// smooth, never kinked). Hovering a slider shades its region. Replaces the curve's own points.
struct CurveRegionSliders: View {
    @Binding var points: [SIMD2<Double>]
    let histogram: [Float]
    @State private var values: [Double] = [0, 0, 0, 0]
    @State private var activeRegion: Int?

    private static let regionCenters: [Double] = [0.125, 0.375, 0.625, 0.875]
    private static let regionNames = ["Shadows", "Darks", "Lights", "Highlights"]
    private static let reach: [Double] = [0.1, 0.13, 0.13, 0.1]

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                CurveBackdrop(points: points, histogram: histogram)
                GeometryReader { geo in
                    ForEach(0..<4, id: \.self) { region in
                        Rectangle()
                            .fill(Color.white.opacity(activeRegion == region ? 0.07 : 0))
                            .frame(width: geo.size.width / 4)
                            .offset(x: geo.size.width / 4 * CGFloat(region))
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(height: 140)
            ForEach(0..<4, id: \.self) { region in
                XBipolarSlider(title: Self.regionNames[region], value: binding(for: region), range: -1...1)
                    .onHover { activeRegion = $0 ? region : (activeRegion == region ? nil : activeRegion) }
            }
        }
        .onAppear(perform: loadFromPoints)
    }

    private func binding(for region: Int) -> Binding<Double> {
        Binding(get: { values[region] }, set: { newValue in
            values[region] = newValue
            points = [SIMD2(0, 0)] + (0..<4).map { i in
                let x = Self.regionCenters[i]
                return SIMD2(x, clampUnit(x + values[i] * Self.reach[i]))
            } + [SIMD2(1, 1)]
        })
    }

    /// Picks up the current curve's values when it already has this exact region layout.
    private func loadFromPoints() {
        let current = normalizedCurve(points)
        guard current.count == 6 else { return }
        for i in 0..<4 where abs(current[i + 1].x - Self.regionCenters[i]) < 0.001 {
            values[i] = (current[i + 1].y - Self.regionCenters[i]) / Self.reach[i]
        }
    }
}

// MARK: - 2. Targeted Drag

struct CurveTargetedDrag: View {
    @Binding var points: [SIMD2<Double>]
    let histogram: [Float]
    @State private var focusX: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TargetedCurveGraph(points: $points, histogram: histogram, focusX: $focusX)
            Text(curveFocusCaption(points: points, histogram: histogram, focusX: focusX, withZones: false))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 3. Zone Grid

struct CurveZoneGrid: View {
    @Binding var points: [SIMD2<Double>]
    let histogram: [Float]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PointCurveEditor(
                points: $points, histogram: histogram,
                snapX: CurveZones.snapped, showsReadout: true, grid: .zones,
                readout: { x, y in "Zone \(CurveZones.numeral(ofDisplay: x)) → \(CurveZones.numeral(ofDisplay: y))" }
            )
            CurveZoneAxisLabels()
        }
    }
}

// MARK: - 4. Ramp Preview

struct CurveRampPreview: View {
    @Binding var points: [SIMD2<Double>]
    let histogram: [Float]

    var body: some View {
        VStack(spacing: 8) {
            PointCurveEditor(points: $points, histogram: histogram, showsReadout: true)
            CurveRampStrip(points: points)
        }
    }
}

// MARK: - 5. Refined Points

struct CurveRefinedPoints: View {
    @Binding var points: [SIMD2<Double>]
    let histogram: [Float]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PointCurveEditor(
                points: $points, histogram: histogram, height: 190,
                pointsOnlyOnHover: true, showsReadout: true, snapsToDiagonal: true, hitRadius: 20, grid: .none
            )
            Text("Drag anywhere to add · ⇧ fine · double-click a point to remove")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 6. Presets + Amount

struct CurvePresets: View {
    @Binding var points: [SIMD2<Double>]
    let histogram: [Float]

    var body: some View {
        VStack(spacing: 10) {
            CurveBackdrop(points: points, histogram: histogram).frame(height: 120)
            CurvePresetChips(points: $points)
        }
    }
}

// MARK: - Shared caption

/// "Tone 42 → 51 · 18% of the photo is around here", optionally with zones — the readout under
/// the targeted-drag graph.
func curveFocusCaption(points: [SIMD2<Double>], histogram: [Float], focusX: Double?, withZones: Bool) -> String {
    guard let x = focusX else { return "Hover a tone, then drag up or down" }
    let y = clampUnit(curveSpline(points).evaluate(x))
    let share = Int((histogramShare(histogram, around: x) * 100).rounded())
    let tones = withZones
        ? "Zone \(CurveZones.numeral(ofDisplay: x)) → \(CurveZones.numeral(ofDisplay: y))  (\(Int((x * 100).rounded())) → \(Int((y * 100).rounded())))"
        : "Tone \(Int((x * 100).rounded())) → \(Int((y * 100).rounded()))"
    return "\(tones)  ·  \(share)% of the photo"
}
