import SwiftUI
import AppKit
import RawEngine

/// Candidate controls that show what a setting is doing to *the photo that's open*, not just a
/// number — the direction the tone-mapper Curve Carousel proved out (see
/// `ToneMapperPickerStyles.swift`). Each is driven by live render data from
/// `EditorRenderCoordinator` (`luminanceHistogram`, `toneStats`) and bound to the real edit field,
/// and shown in `EditorSidebarView`'s Developer Mode comparison panels so they can be tried on real
/// photos. Once one wins per parameter, it replaces the plain slider and the rest get deleted.

private let shadowClipColor = Color(red: 0.36, green: 0.56, blue: 1.0)
private let highlightClipColor = Color(red: 1.0, green: 0.36, blue: 0.3)

private func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}

private func unit(_ value: Double, in range: ClosedRange<Double>) -> Double {
    (value - range.lowerBound) / (range.upperBound - range.lowerBound)
}

/// "0.4%" / "12%" — one decimal only while it's small enough for that to matter.
private func percentText(_ fraction: Float) -> String {
    fraction < 0.01 ? String(format: "%.1f%%", fraction * 100) : String(format: "%.0f%%", fraction * 100)
}

/// Visual strength for a clip fraction — perceptual rather than linear, so a meaningful-but-small
/// clip (0.5%) already reads clearly and 5%+ is fully lit.
private func clipIntensity(_ fraction: Float) -> Double {
    fraction < 0.0005 ? 0 : min(1, Double(fraction * 20).squareRoot())
}

/// Shared title row: name on the left, optional accessory (clip badges etc.), value pill on the
/// right — same chrome as `slider(...)`'s header.
private struct ControlHeader<Accessory: View>: View {
    let title: String
    let valueText: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                .foregroundStyle(.secondary)
            Spacer()
            accessory
            Text(valueText)
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

/// Small "▲ 0.4%" badge for a clipped end — only shown when something is actually clipped.
private struct ClipBadge: View {
    let fraction: Float
    let color: Color
    let icon: String

    var body: some View {
        if clipIntensity(fraction) > 0 {
            HStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 7))
                Text(percentText(fraction)).font(.caption2.monospacedDigit())
            }
            .foregroundStyle(color)
            .transition(.opacity)
        }
    }
}

// MARK: - Exposure A · Clip-warning ends

/// The current Exposure slider, unchanged, except each end of the track glows (blue = crushed
/// shadows, red = blown highlights) in proportion to how much of *this photo* is clipped at that
/// end, with a percentage badge in the header. The least disruptive option — same control, one
/// extra piece of truth.
struct ExposureClipEndsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let resetValue: Double
    let stats: ImageToneStats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ControlHeader(title: "Exposure", valueText: String(format: "%.2f", value)) {
                ClipBadge(fraction: stats.shadowClipFraction, color: shadowClipColor, icon: "arrowtriangle.left.fill")
                ClipBadge(fraction: stats.highlightClipFraction, color: highlightClipColor, icon: "arrowtriangle.right.fill")
            }
            MinimalSlider(
                value: $value, range: range, resetValue: resetValue,
                ticks: [-4, -3, -2, -1, 0, 1, 2, 3, 4], trackStyle: .hairline, thumbShape: .diamond
            )
            .overlay(alignment: .leading) { glow(shadowClipColor, stats.shadowClipFraction) }
            .overlay(alignment: .trailing) { glow(highlightClipColor, stats.highlightClipFraction) }
        }
        .animation(.easeOut(duration: 0.2), value: stats)
    }

    private func glow(_ color: Color, _ fraction: Float) -> some View {
        let intensity = clipIntensity(fraction)
        return Capsule()
            .fill(color)
            .frame(width: 8 + 36 * intensity, height: 3)
            .blur(radius: 2.5)
            .opacity(intensity == 0 ? 0 : 0.35 + 0.65 * intensity)
            .allowsHitTesting(false)
    }
}

// MARK: - Exposure B · Histogram track

/// The track *is* the photo's luminance histogram — drag anywhere on it to set exposure, and
/// watch the tones slide left/right under the handle as the render catches up. Clipped pixels pile
/// up as colored bars against the edges. Shows "where are my tones" and "what am I doing to them"
/// in one place.
struct ExposureHistogramTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let resetValue: Double
    let histogram: [Float]
    let stats: ImageToneStats
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ControlHeader(title: "Exposure", valueText: String(format: "%.2f", value)) {
                ClipBadge(fraction: stats.shadowClipFraction, color: shadowClipColor, icon: "arrowtriangle.left.fill")
                ClipBadge(fraction: stats.highlightClipFraction, color: highlightClipColor, icon: "arrowtriangle.right.fill")
            }
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let handleX = w * unit(value, in: range)
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(uiColors.recessedTrackBackground)
                    histogramShape(width: w, height: h)
                        .fill(Color.white.opacity(0.22))
                    // Clip piles against each edge.
                    Rectangle()
                        .fill(shadowClipColor)
                        .frame(width: 3, height: h * clipIntensity(stats.shadowClipFraction))
                    Rectangle()
                        .fill(highlightClipColor)
                        .frame(width: 3, height: h * clipIntensity(stats.highlightClipFraction))
                        .offset(x: w - 3)
                    // Handle: a hairline through the histogram with the app's diamond thumb below.
                    Rectangle()
                        .fill(uiColors.accentColor)
                        .frame(width: 1.5, height: h)
                        .offset(x: handleX - 0.75)
                    Rectangle()
                        .fill(.white)
                        .frame(width: 9, height: 9)
                        .rotationEffect(.degrees(45))
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                        .offset(x: handleX - 4.5, y: 4.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6).inset(by: -6))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    value = range.lowerBound + clamp(drag.location.x / w, 0...1) * (range.upperBound - range.lowerBound)
                })
                .onTapGesture(count: 2) { value = resetValue }
            }
            .frame(height: 40)
            HStack {
                Text("−4").font(.system(size: 8).monospacedDigit())
                Spacer()
                Text("0").font(.system(size: 8).monospacedDigit())
                Spacer()
                Text("+4").font(.system(size: 8).monospacedDigit())
            }
            .foregroundStyle(.tertiary)
        }
        .animation(.easeOut(duration: 0.2), value: stats)
    }

    private func histogramShape(width: CGFloat, height: CGFloat) -> Path {
        Path { p in
            guard histogram.count > 1 else { return }
            p.move(to: CGPoint(x: 0, y: height))
            for (i, v) in histogram.enumerated() {
                p.addLine(to: CGPoint(x: width * CGFloat(i) / CGFloat(histogram.count - 1), y: height - height * CGFloat(v) * 0.85))
            }
            p.addLine(to: CGPoint(x: width, y: height))
            p.closeSubpath()
        }
    }
}

// MARK: - Exposure C · Scrub + sparkline

/// The kept "Scrub Number" slider idea, made photo-aware: a compact row with a mini histogram
/// sparkline (edges tinted where clipped) and a draggable number. Takes one line instead of two,
/// for a denser sidebar.
struct ExposureScrubSparkline: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let resetValue: Double
    let histogram: [Float]
    let stats: ImageToneStats
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        HStack(spacing: 10) {
            Text("Exposure")
                .font(.scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .bottomLeading) {
                    Path { p in
                        guard histogram.count > 1 else { return }
                        p.move(to: CGPoint(x: 0, y: h))
                        for (i, v) in histogram.enumerated() {
                            p.addLine(to: CGPoint(x: w * CGFloat(i) / CGFloat(histogram.count - 1), y: h - h * CGFloat(v)))
                        }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(
                        stops: [
                            .init(color: shadowClipColor.opacity(clipIntensity(stats.shadowClipFraction)), location: 0),
                            .init(color: Color.white.opacity(0.25), location: 0.12),
                            .init(color: Color.white.opacity(0.25), location: 0.88),
                            .init(color: highlightClipColor.opacity(clipIntensity(stats.highlightClipFraction)), location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    ))
                }
            }
            .frame(height: 18)
            XScrubNumber(title: "", value: $value, range: range)
                .frame(width: 84)
                .onTapGesture(count: 2) { value = resetValue }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - White Balance A · As-shot marker

/// Temp/Tint as horizontal gradient tracks with the camera's *as-shot* value marked on each — so
/// "how far have I moved from what the camera saw" is visible, and read out as a delta ("+350K").
/// Double-click snaps back to as-shot.
struct WhiteBalanceAsShotSliders: View {
    @Binding var temperature: Double
    @Binding var tint: Double
    let asShotTemperature: Double
    let asShotTint: Double
    var temperatureRange: ClosedRange<Double> = 2000...12000
    var tintRange: ClosedRange<Double> = -150...150

    var body: some View {
        VStack(spacing: 14) {
            row(
                title: "Temp", value: $temperature, range: temperatureRange, asShot: asShotTemperature,
                gradient: .neutralTemperature, valueText: "\(Int(temperature.rounded()))K",
                deltaText: delta(temperature - asShotTemperature, unit: "K")
            )
            row(
                title: "Tint", value: $tint, range: tintRange, asShot: asShotTint,
                gradient: .neutralTint, valueText: signed(tint),
                deltaText: delta(tint - asShotTint, unit: "")
            )
        }
    }

    private func row(
        title: String, value: Binding<Double>, range: ClosedRange<Double>, asShot: Double,
        gradient: Gradient, valueText: String, deltaText: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ControlHeader(title: title, valueText: valueText) {
                if let deltaText {
                    Text(deltaText).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                let asShotX = w * unit(asShot, in: range)
                let x = w * unit(value.wrappedValue, in: range)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 5)
                    // As-shot marker: a notch above the track plus a tiny label below it.
                    Rectangle().fill(Color.white.opacity(0.7)).frame(width: 1, height: 14).offset(x: asShotX - 0.5)
                    Text("as shot")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .offset(x: asShotX - 14, y: 13)
                    Rectangle()
                        .fill(.white)
                        .frame(width: 9, height: 9)
                        .rotationEffect(.degrees(45))
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                        .offset(x: x - 4.5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    value.wrappedValue = range.lowerBound + clamp(drag.location.x / w, 0...1) * (range.upperBound - range.lowerBound)
                })
                .onTapGesture(count: 2) { value.wrappedValue = asShot }
            }
            .frame(height: 18)
            .padding(.bottom, 6)
        }
    }

    private func signed(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    private func delta(_ value: Double, unit: String) -> String? {
        let rounded = Int(value.rounded())
        guard rounded != 0 else { return nil }
        return (rounded > 0 ? "+\(rounded)" : "\(rounded)") + unit + " from as shot"
    }
}

// MARK: - White Balance · Cast analysis (shared)

/// The rendered photo's overall color cast, derived from `ImageToneStats`' mean color — warm(+)/
/// cool(−) and green(+)/magenta(−) components, roughly −1...1. Doesn't claim the photo *should* be
/// neutral (plenty shouldn't be — a sunset, a tungsten-lit room), just reports where it sits.
private struct ColorCast {
    let warm: Double
    let green: Double
    /// The mean color re-lit to a fixed mid brightness, so a dark photo's cast still reads.
    let swatch: Color

    init(_ stats: ImageToneStats) {
        let r = Double(stats.meanRed), g = Double(stats.meanGreen), b = Double(stats.meanBlue)
        let luma = max((r + g + b) / 3, 0.02)
        warm = clamp((r - b) / luma * 1.5, -1...1)
        green = clamp((g - (r + b) / 2) / luma * 3, -1...1)
        let peak = max(r, g, b, 0.001)
        swatch = Color(red: r / peak * 0.7, green: g / peak * 0.7, blue: b / peak * 0.7)
    }

    var description: String {
        var parts: [String] = []
        if abs(warm) > 0.08 { parts.append(warm > 0 ? "Warm" : "Cool") }
        if abs(green) > 0.08 { parts.append(green > 0 ? "Green" : "Magenta") }
        return parts.isEmpty ? "Neutral" : parts.joined(separator: " · ")
    }
}

/// The cast plotted on a small warm/cool × green/magenta cross — a dot in the cast's own color,
/// with a ring marking neutral center.
private struct ColorCastPlot: View {
    let cast: ColorCast
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let dot = CGPoint(x: size.width / 2 * (1 + cast.warm * 0.85), y: size.height / 2 * (1 - cast.green * 0.85))
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(uiColors.recessedTrackBackground)
                // Axis tints: cool ← → warm, green ↑ ↓ magenta.
                LinearGradient(colors: [Color.blue.opacity(0.18), .clear, Color.orange.opacity(0.18)], startPoint: .leading, endPoint: .trailing)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                LinearGradient(colors: [Color.green.opacity(0.14), .clear, Color.pink.opacity(0.14)], startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Path { p in
                    p.move(to: CGPoint(x: size.width / 2, y: 5)); p.addLine(to: CGPoint(x: size.width / 2, y: size.height - 5))
                    p.move(to: CGPoint(x: 5, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width - 5, y: size.height / 2))
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1).frame(width: 11, height: 11)
                Circle()
                    .fill(cast.swatch)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .position(dot)
            }
        }
    }
}

/// The compact cast readout that sits beside Temp/Tint in `ColorBalanceBarView`'s WB group: cross
/// plot plus a one-word description. Its own `View` reading `coordinator.toneStats` inside its own
/// `body`, so a new render's stats only re-diff this little view, not the whole color bar.
struct WhiteBalanceCastIndicator: View {
    let coordinator: EditorRenderCoordinator
    var plotSize: CGFloat = 56

    var body: some View {
        let cast = ColorCast(coordinator.toneStats)
        VStack(spacing: 5) {
            ColorCastPlot(cast: cast)
                .frame(width: plotSize, height: plotSize)
            Text(cast.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .help("Average color of the photo — the dot moves toward the center ring as it gets more neutral")
        .animation(.easeOut(duration: 0.25), value: coordinator.toneStats)
    }
}

// MARK: - White Balance B · Cast meter

/// Reads the rendered photo's *average color* and plots its cast next to a swatch of that cast —
/// as Temp/Tint move, the dot visibly heads toward (or away from) neutral center. Compact Temp/Tint
/// sliders underneath do the adjusting.
struct WhiteBalanceCastMeter: View {
    @Binding var temperature: Double
    @Binding var tint: Double
    let asShotTemperature: Double
    let asShotTint: Double
    let stats: ImageToneStats
    var temperatureRange: ClosedRange<Double> = 2000...12000
    var tintRange: ClosedRange<Double> = -150...150

    var body: some View {
        let cast = ColorCast(stats)
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ColorCastPlot(cast: cast).frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(cast.swatch).frame(width: 22, height: 22)
                        RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.7)).frame(width: 22, height: 22)
                    }
                    Text("Photo average vs. neutral")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(cast.description)
                        .font(.caption.weight(.medium))
                }
                Spacer(minLength: 0)
            }
            slider("Temp", value: $temperature, range: temperatureRange, resetValue: asShotTemperature, trackStyle: .hairline, thumbShape: .diamond)
            slider("Tint", value: $tint, range: tintRange, resetValue: asShotTint, trackStyle: .hairline, thumbShape: .diamond)
        }
        .animation(.easeOut(duration: 0.25), value: stats)
    }
}

// MARK: - Contrast (shared math)

/// Color Balance RGB's contrast, exactly as `ColorBalanceRGBProcessor` applies it: in linear
/// luminance, `Y' = grey × (Y / grey)^(1 + contrast)` around the 18.45% grey fulcrum. In stops
/// (log2 relative to grey) that's just a straight line through middle grey with slope
/// `1 + contrast` — which is what every visualization below leans on.
private let contrastGreyFulcrum = 0.1845

private func applyContrast(linear y: Double, _ contrast: Double) -> Double {
    y <= 0 ? 0 : contrastGreyFulcrum * pow(y / contrastGreyFulcrum, 1 + contrast)
}

/// Display ↔ linear, approximated as a plain 2.2 gamma — close enough to the preview's encoding
/// for placing histogram bins and ramp stops; not used for any actual rendering.
private func displayToLinear(_ v: Double) -> Double { pow(max(v, 0), 2.2) }
private func linearToDisplay(_ v: Double) -> Double { pow(max(v, 0), 1 / 2.2) }

private func signedValue(_ value: Double) -> String {
    let text = String(format: "%.2f", value)
    return value > 0.004 ? "+" + text : (value < -0.004 ? text : "0.00")
}

// MARK: - Contrast A · Pivot line

/// Contrast drawn as what it literally is: a line through middle grey on a stops-in × stops-out
/// graph, rotating steeper (more contrast) or flatter (less) around the grey pivot. The photo's
/// own tones sit behind it as a histogram on the same stops axis, so you can see which tones get
/// pushed apart or pulled together. Drag up/down on the graph to change it; double-click resets.
struct ContrastPivotGraph: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -0.5...0.5
    let histogram: [Float]
    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var dragStart: Double?

    /// Stops relative to middle grey shown on each axis.
    private let evRange = -7.0...3.0

    private func u(_ ev: Double) -> CGFloat { CGFloat((ev - evRange.lowerBound) / (evRange.upperBound - evRange.lowerBound)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ControlHeader(title: "Contrast", valueText: signedValue(value)) { EmptyView() }
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let pivot = CGPoint(x: u(0) * w, y: (1 - u(0)) * h)
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(uiColors.recessedTrackBackground)
                    histogramPath(width: w, height: h).fill(Color.white.opacity(0.12))
                    // Stop gridlines.
                    Path { p in
                        for ev in stride(from: evRange.lowerBound + 1, to: evRange.upperBound, by: 1) {
                            p.move(to: CGPoint(x: u(ev) * w, y: 0)); p.addLine(to: CGPoint(x: u(ev) * w, y: h))
                        }
                    }
                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
                    // Identity (no contrast change).
                    Path { p in p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: w, y: 0)) }
                        .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    // The contrast line: ev_out = (1 + c) × ev_in.
                    Path { p in
                        let slope = 1 + value
                        p.move(to: CGPoint(x: 0, y: (1 - u(evRange.lowerBound * slope)) * h))
                        p.addLine(to: CGPoint(x: w, y: (1 - u(evRange.upperBound * slope)) * h))
                    }
                    .stroke(uiColors.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    Circle()
                        .fill(Color(white: 0.46))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                        .position(pivot)
                    Text("18% grey")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .position(x: pivot.x + 26, y: pivot.y + 10)
                    Text(value > 0.004 ? "Punchier" : (value < -0.004 ? "Flatter" : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let start = dragStart ?? value
                    dragStart = start
                    let factor = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1
                    value = clamp(start - Double(drag.translation.height / h) * factor, range)
                }.onEnded { _ in dragStart = nil })
                .onTapGesture(count: 2) { value = 0 }
            }
            .frame(height: 130)
        }
    }

    /// The display-referred luminance histogram re-plotted on the stops axis (bins below the
    /// graph's darkest stop fall off the left edge).
    private func histogramPath(width: CGFloat, height: CGFloat) -> Path {
        Path { p in
            guard histogram.count > 1 else { return }
            var started = false
            for (i, count) in histogram.enumerated() {
                let display = (Double(i) + 0.5) / Double(histogram.count)
                let ev = log2(max(displayToLinear(display), 1e-6) / contrastGreyFulcrum)
                guard evRange.contains(ev) else { continue }
                let x = u(ev) * width
                let y = height - height * CGFloat(count) * 0.8
                if !started {
                    p.move(to: CGPoint(x: x, y: height))
                    started = true
                }
                p.addLine(to: CGPoint(x: x, y: y))
            }
            if started {
                p.addLine(to: CGPoint(x: width, y: height))
                p.closeSubpath()
            }
        }
    }
}

// MARK: - Contrast B · Tone spread

/// Measures the photo: where the middle 90% of its tones actually sit (5th–95th percentile of the
/// rendered luminance), drawn as a bracket over a black→white strip with the median marked. Drag
/// contrast and watch the bracket widen or narrow on the real render. Answers "is this photo flat
/// or punchy right now?" with data rather than by eye.
struct ContrastToneSpread: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -0.5...0.5
    let histogram: [Float]
    @Environment(ColorSchemeStore.self) private var uiColors

    private var percentiles: (low: Double, median: Double, high: Double)? {
        let total = histogram.reduce(0, +)
        guard histogram.count > 1, total > 0 else { return nil }
        func percentile(_ q: Float) -> Double {
            var running: Float = 0
            for (i, count) in histogram.enumerated() {
                running += count
                if running / total >= q { return (Double(i) + 0.5) / Double(histogram.count) }
            }
            return 1
        }
        return (percentile(0.05), percentile(0.5), percentile(0.95))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            XBipolarSlider(title: "Contrast", value: $value, range: range)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 8)
                        .clipShape(Capsule())
                        .opacity(0.55)
                    if let p = percentiles {
                        // Bracket over the middle 90%.
                        Path { path in
                            let x0 = p.low * w, x1 = p.high * w
                            path.move(to: CGPoint(x: x0, y: 16)); path.addLine(to: CGPoint(x: x0, y: 4))
                            path.addLine(to: CGPoint(x: x1, y: 4)); path.addLine(to: CGPoint(x: x1, y: 16))
                        }
                        .stroke(uiColors.accentColor, lineWidth: 1.5)
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2, height: 14)
                            .offset(x: p.median * w - 1)
                    }
                }
                .frame(height: 20)
            }
            .frame(height: 20)
            if let p = percentiles {
                Text("Middle 90% of tones span \(Int(((p.high - p.low) * 100).rounded()))% of the range")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.easeOut(duration: 0.25), value: histogram)
    }
}

// MARK: - Contrast C · Ramp mapping

/// Two grey ramps — input on top, the same ramp through the current contrast on the bottom — with
/// a line joining each tone to where it lands. Lines fanning outward from middle grey = tones
/// being pushed apart (more contrast); converging = pulled together. The exact math, no photo
/// needed, so it reads the same on every image.
struct ContrastRampMapping: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -0.5...0.5
    /// `false` drops the two grey gradient ramps and keeps only the connector lines (the editor
    /// sidebar's variant) — the endpoints are then marked with small ticks instead.
    var showsRamps = true
    /// When given, the photo's own darkest and brightest tones are marked on the fan — measured
    /// from the current render (0.5th/99.5th percentile of `histogram`), so they move with
    /// Exposure as well as Contrast. The bottom end is where that tone lands now; the top end is
    /// where it came from before contrast (the exact inverse of `applyContrast`). A marker turns
    /// red/blue when `stats` says that end is clipping. Approximate where later modules (curve,
    /// LUT) also reshape tones, since the histogram is of the finished render.
    var histogram: [Float]? = nil
    var stats: ImageToneStats? = nil
    @Environment(ColorSchemeStore.self) private var uiColors

    private func output(_ display: Double) -> Double {
        min(max(linearToDisplay(applyContrast(linear: displayToLinear(display), value)), 0), 1)
    }

    /// Inverse of `output` — the pre-contrast tone that lands on `display`.
    private func input(_ display: Double) -> Double {
        let y = displayToLinear(display)
        let pre = y <= 0 ? 0 : contrastGreyFulcrum * pow(y / contrastGreyFulcrum, 1 / (1 + value))
        return min(max(linearToDisplay(pre), 0), 1)
    }

    /// The photo's darkest/brightest tones (display-referred, 0...1) in the current render.
    private var tonalExtremes: (dark: Double, bright: Double)? {
        guard let histogram, histogram.count > 1 else { return nil }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }
        let n = Double(histogram.count)
        var running: Float = 0
        var dark = 0.0, bright = 1.0, foundDark = false
        for (i, count) in histogram.enumerated() {
            running += count
            if !foundDark, running / total >= 0.005 { dark = Double(i) / n; foundDark = true }
            if running / total >= 0.995 { bright = Double(i + 1) / n; break }
        }
        return (dark, bright)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ControlHeader(title: "Contrast", valueText: signedValue(value)) { EmptyView() }
            GeometryReader { geo in
                let w = geo.size.width
                let rampHeight: CGFloat = 10
                let gap = geo.size.height - rampHeight * 2
                ZStack(alignment: .topLeading) {
                    if showsRamps {
                        LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                            .frame(height: rampHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        // Hairline baselines where the ramps would be, so the lines have ends.
                        Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1).offset(y: rampHeight - 1)
                        Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1).offset(y: rampHeight + gap)
                    }
                    Path { p in
                        for i in 1..<16 {
                            let t = Double(i) / 16
                            p.move(to: CGPoint(x: t * w, y: rampHeight))
                            p.addLine(to: CGPoint(x: output(t) * w, y: rampHeight + gap))
                        }
                    }
                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
                    // Middle grey's own connector, highlighted — it never moves.
                    Path { p in
                        let grey = linearToDisplay(contrastGreyFulcrum)
                        p.move(to: CGPoint(x: grey * w, y: rampHeight))
                        p.addLine(to: CGPoint(x: grey * w, y: rampHeight + gap))
                    }
                    .stroke(uiColors.accentColor, lineWidth: 1.5)
                    if let extremes = tonalExtremes {
                        extremeMarker(
                            label: "darkest", bottom: extremes.dark, width: w, top: rampHeight, gap: gap,
                            clipped: (stats?.shadowClipFraction ?? 0) > 0.005, clipColor: shadowClipColor, alignLeading: true
                        )
                        extremeMarker(
                            label: "brightest", bottom: extremes.bright, width: w, top: rampHeight, gap: gap,
                            clipped: (stats?.highlightClipFraction ?? 0) > 0.005, clipColor: highlightClipColor, alignLeading: false
                        )
                    }
                    if showsRamps {
                        LinearGradient(
                            stops: (0...16).map { i in
                                let t = Double(i) / 16
                                return .init(color: Color(white: output(t)), location: t)
                            },
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(height: rampHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .offset(y: rampHeight + gap)
                    }
                }
            }
            .frame(height: 64)
            .padding(.bottom, tonalExtremes == nil ? 0 : 10)
            MinimalSlider(
                value: $value, range: range, resetValue: 0,
                ticks: [-0.5, -0.25, 0, 0.25, 0.5], trackStyle: .hairline, thumbShape: .diamond
            )
        }
        .animation(.easeOut(duration: 0.2), value: histogram)
    }

    /// One highlighted connector for the photo's darkest or brightest tone: from where it sat
    /// before contrast (top) to where it lands now (bottom), with end dots and a tiny label under
    /// the bottom end. `clipped` recolors it (and relabels it) when that end is blowing/crushing.
    private func extremeMarker(
        label: String, bottom: Double, width w: CGFloat, top: CGFloat, gap: CGFloat,
        clipped: Bool, clipColor: Color, alignLeading: Bool
    ) -> some View {
        let color = clipped ? clipColor : Color.white.opacity(0.9)
        let topX = input(bottom) * w
        let bottomX = bottom * w
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: topX, y: top))
                p.addLine(to: CGPoint(x: bottomX, y: top + gap))
            }
            .stroke(color, lineWidth: 1.5)
            Circle().fill(color).frame(width: 5, height: 5).offset(x: topX - 2.5, y: top - 2.5)
            Circle().fill(color).frame(width: 7, height: 7).offset(x: bottomX - 3.5, y: top + gap - 3.5)
            Text(clipped ? (alignLeading ? "crushed" : "clipped") : label)
                .font(.system(size: 8))
                .foregroundStyle(clipped ? color : Color.secondary)
                .fixedSize()
                .frame(width: 60, alignment: alignLeading ? .leading : .trailing)
                .offset(x: alignLeading ? max(bottomX - 4, 0) : min(bottomX - 56, w - 60), y: top + gap + 6)
        }
    }
}
