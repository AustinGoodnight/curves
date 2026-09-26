import SwiftUI
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

// MARK: - White Balance B · Cast meter

/// Reads the rendered photo's *average color* and plots its cast on a small warm/cool ×
/// green/magenta cross, next to a swatch of that cast — as Temp/Tint move, the dot visibly heads
/// toward (or away from) neutral center. Doesn't claim the photo *should* be neutral (plenty
/// shouldn't be), just shows where it sits. Compact Temp/Tint sliders underneath do the adjusting.
struct WhiteBalanceCastMeter: View {
    @Binding var temperature: Double
    @Binding var tint: Double
    let asShotTemperature: Double
    let asShotTint: Double
    let stats: ImageToneStats
    var temperatureRange: ClosedRange<Double> = 2000...12000
    var tintRange: ClosedRange<Double> = -150...150
    @Environment(ColorSchemeStore.self) private var uiColors

    /// Warm(+)/cool(−) and green(+)/magenta(−) components of the mean color, roughly −1...1.
    private var cast: (warm: Double, green: Double) {
        let r = Double(stats.meanRed), g = Double(stats.meanGreen), b = Double(stats.meanBlue)
        let luma = max((r + g + b) / 3, 0.02)
        return (warm: clamp((r - b) / luma * 1.5, -1...1), green: clamp((g - (r + b) / 2) / luma * 3, -1...1))
    }

    /// The mean color re-lit to a fixed mid brightness, so a dark photo's cast still reads.
    private var castSwatch: Color {
        let r = Double(stats.meanRed), g = Double(stats.meanGreen), b = Double(stats.meanBlue)
        let peak = max(r, g, b, 0.001)
        return Color(red: r / peak * 0.7, green: g / peak * 0.7, blue: b / peak * 0.7)
    }

    private var castDescription: String {
        let (warm, green) = cast
        var parts: [String] = []
        if abs(warm) > 0.08 { parts.append(warm > 0 ? "Warm" : "Cool") }
        if abs(green) > 0.08 { parts.append(green > 0 ? "Green" : "Magenta") }
        return parts.isEmpty ? "Neutral" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                crossPlot.frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(castSwatch).frame(width: 22, height: 22)
                        RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.7)).frame(width: 22, height: 22)
                    }
                    Text("Photo average vs. neutral")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(castDescription)
                        .font(.caption.weight(.medium))
                }
                Spacer(minLength: 0)
            }
            slider("Temp", value: $temperature, range: temperatureRange, resetValue: asShotTemperature, trackStyle: .hairline, thumbShape: .diamond)
            slider("Tint", value: $tint, range: tintRange, resetValue: asShotTint, trackStyle: .hairline, thumbShape: .diamond)
        }
        .animation(.easeOut(duration: 0.25), value: stats)
    }

    private var crossPlot: some View {
        GeometryReader { geo in
            let size = geo.size
            let (warm, green) = cast
            let dot = CGPoint(x: size.width / 2 * (1 + warm * 0.9), y: size.height / 2 * (1 - green * 0.9))
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(uiColors.recessedTrackBackground)
                // Axis tints: cool ← → warm, magenta ↓ ↑ green.
                LinearGradient(colors: [Color.blue.opacity(0.18), .clear, Color.orange.opacity(0.18)], startPoint: .leading, endPoint: .trailing)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                LinearGradient(colors: [Color.green.opacity(0.14), .clear, Color.pink.opacity(0.14)], startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Path { p in
                    p.move(to: CGPoint(x: size.width / 2, y: 6)); p.addLine(to: CGPoint(x: size.width / 2, y: size.height - 6))
                    p.move(to: CGPoint(x: 6, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width - 6, y: size.height / 2))
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1).frame(width: 12, height: 12)
                Circle()
                    .fill(castSwatch)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .position(dot)
            }
        }
    }
}
