import SwiftUI
import AppKit

/// Experimental slider designs, none wired to a real edit parameter yet. (A wider batch of
/// selects/toggles/2D pads was cut — too generic, borrowed from other domains rather than grounded
/// in a photo-editing decision.) They live in the Component Gallery's "Slider Experiments" section
/// (`ExperimentalControlsGallery`, bottom of this file), same process as `ToneMapperPickerStyles`:
/// try them live, keep the winners, promote them into the real editor, delete the rest.
///
/// Every control is generic (plain `Binding`s, no `PhotoAsset`/`Stage`) and draws in the editor's
/// existing visual language — `recessedTrackBackground` grooves, `accentColor` fills, the glossy
/// white thumb dot, `.caption` labels — so a winner can drop straight into the real UI.

// MARK: - Shared helpers

private func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}

private func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
    (value - range.lowerBound) / (range.upperBound - range.lowerBound)
}

private func valueAt(fraction f: Double, in range: ClosedRange<Double>) -> Double {
    range.lowerBound + clamped(f, 0...1) * (range.upperBound - range.lowerBound)
}

private func signedText(_ value: Double, decimals: Int = 2) -> String {
    let text = String(format: "%.\(decimals)f", value)
    return value > 0 ? "+" + text : text
}

/// The glossy white thumb dot every existing slider uses.
private struct GlossyThumb: View {
    var diameter: CGFloat = 14

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.75))
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
    }
}

private struct ControlLabel: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.primary)
        }
    }
}

// MARK: - Sliders

/// 1. LED meter — the track is a row of segments that light up to the value, like a VU meter.
/// Reads "how much" at a glance with a stepped, hardware feel.
struct XMeterSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var segments = 24
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(spacing: 6) {
            ControlLabel(title: title, value: String(format: "%.0f%%", fraction(of: value, in: range) * 100))
            GeometryReader { geo in
                let lit = Int((fraction(of: value, in: range) * Double(segments)).rounded())
                HStack(spacing: 2) {
                    ForEach(0..<segments, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(i < lit ? uiColors.accentColor.opacity(0.45 + 0.55 * Double(i) / Double(segments)) : Color.white.opacity(0.08))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    value = valueAt(fraction: drag.location.x / geo.size.width, in: range)
                })
            }
            .frame(height: 12)
        }
    }
}

/// 2. Bipolar fill — the fill grows outward from the center (zero), not from the left edge, so
/// "which direction and how far" is the whole picture. Good for Contrast/Chroma/Tint-style fields.
struct XBipolarSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(spacing: 6) {
            ControlLabel(title: title, value: signedText(value))
            GeometryReader { geo in
                let w = geo.size.width
                let zeroX = w * fraction(of: 0, in: range)
                let x = w * fraction(of: value, in: range)
                ZStack(alignment: .leading) {
                    Capsule().fill(uiColors.recessedTrackBackground).frame(height: 6)
                    Capsule()
                        .fill(uiColors.accentColor)
                        .frame(width: abs(x - zeroX), height: 6)
                        .offset(x: min(x, zeroX))
                    Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: 12).offset(x: zeroX - 0.5)
                    GlossyThumb().offset(x: x - 7)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    value = valueAt(fraction: drag.location.x / w, in: range)
                })
                .onTapGesture(count: 2) { value = 0 }
            }
            .frame(height: 16)
        }
    }
}

/// 3. Scrub number — no track at all; drag left/right directly on the number (Figma/Blender
/// style), with the resize cursor on hover. Densest possible control for a precise value.
struct XScrubNumber: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -4...4
    var sensitivity: Double = 0.01
    @State private var dragStartValue: Double?
    @State private var isHovering = false

    var body: some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(signedText(value))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(isHovering || dragStartValue != nil ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 5))
                .onHover { hovering in
                    isHovering = hovering
                    if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                    let start = dragStartValue ?? value
                    dragStartValue = start
                    let factor = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                    value = clamped(start + drag.translation.width * sensitivity * factor, range)
                }.onEnded { _ in dragStartValue = nil })
        }
    }
}

/// 4. Range slider — two thumbs bounding a band. For anything that's a span rather than a point:
/// a luminosity mask's range, black/white points, a hue band.
struct XRangeSlider: View {
    let title: String
    @Binding var low: Double
    @Binding var high: Double
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(spacing: 6) {
            ControlLabel(title: title, value: String(format: "%.0f – %.0f", low * 100, high * 100))
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing))
                        .opacity(0.5)
                        .frame(height: 6)
                    Rectangle()
                        .fill(uiColors.accentColor.opacity(0.8))
                        .frame(width: max(0, (high - low) * w), height: 6)
                        .offset(x: low * w)
                    GlossyThumb().offset(x: low * w - 7)
                    GlossyThumb().offset(x: high * w - 7)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let f = clamped(drag.location.x / w, 0...1)
                    // Move whichever thumb is nearer the pointer.
                    if abs(f - low) < abs(f - high) { low = min(f, high) } else { high = max(f, low) }
                })
            }
            .frame(height: 16)
        }
    }
}

/// 5. Hue loupe — a hue-spectrum track whose thumb pops a magnified swatch bubble above itself
/// while dragging, so the exact color picked is visible without the finger/cursor hiding it.
struct XHueLoupeSlider: View {
    @Binding var hue: Double
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 6) {
            ControlLabel(title: "Hue", value: String(format: "%.0f°", hue))
            GeometryReader { geo in
                let w = geo.size.width
                let x = w * hue / 360
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(
                            colors: stride(from: 0.0, through: 1.0, by: 1 / 12).map { Color(hue: $0, saturation: 0.75, brightness: 0.9) },
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(height: 8)
                    GlossyThumb().offset(x: x - 7)
                    if isDragging {
                        VStack(spacing: 2) {
                            Circle()
                                .fill(Color(hue: hue / 360, saturation: 0.75, brightness: 0.9))
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                .frame(width: 30, height: 30)
                            Text(String(format: "%.0f°", hue)).font(.caption2.monospacedDigit())
                        }
                        .offset(x: x - 15, y: -34)
                        .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    withAnimation(.snappy(duration: 0.15)) { isDragging = true }
                    hue = clamped(drag.location.x / w, 0...1) * 360
                }.onEnded { _ in
                    withAnimation(.snappy(duration: 0.2)) { isDragging = false }
                })
            }
            .frame(height: 16)
        }
        .padding(.top, 34)
    }
}

/// 6. Arc gauge — a 180° dial you drag around; the value reads like a speedometer. Compact
/// alternative to a long horizontal track for a single hero parameter.
struct XArcGauge: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height * 2)
            let center = CGPoint(x: geo.size.width / 2, y: size / 2)
            let f = fraction(of: value, in: range)
            ZStack {
                Circle()
                    .trim(from: 0.5, to: 1)
                    .stroke(uiColors.recessedTrackBackground, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                Circle()
                    .trim(from: 0.5, to: 0.5 + 0.5 * f)
                    .stroke(uiColors.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                VStack(spacing: 0) {
                    Text(String(format: "%.0f", f * 100)).font(.title3.monospacedDigit().weight(.semibold))
                    Text(title).font(.caption2).foregroundStyle(.secondary)
                }
                .offset(y: -size * 0.12)
            }
            .frame(width: size - 12, height: size - 12)
            .position(center)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let dx = drag.location.x - center.x
                let dy = drag.location.y - center.y
                // Angle from the left end of the arc (π) sweeping clockwise over the top to 0.
                var angle = atan2(-dy, dx)
                if angle < 0 { angle = dx < 0 ? .pi : 0 }
                value = valueAt(fraction: 1 - Double(angle) / .pi, in: range)
            })
        }
        .frame(height: 90)
    }
}

/// 7. Stepper pill — `−  value  +`, press-and-hold repeats. For values usually nudged by fixed
/// increments (EV stops, rotation degrees) rather than dragged.
struct XStepperPill: View {
    let title: String
    @Binding var value: Double
    var step: Double = 1.0 / 3
    var range: ClosedRange<Double> = -4...4
    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var repeatTimer: Timer?

    var body: some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 0) {
                stepButton("minus", delta: -step)
                Text(signedText(value))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .frame(width: 52)
                stepButton("plus", delta: step)
            }
            .background(uiColors.recessedTrackBackground, in: Capsule())
        }
    }

    private func stepButton(_ icon: String, delta: Double) -> some View {
        Image(systemName: icon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.35, pressing: { pressing in
                repeatTimer?.invalidate()
                if pressing {
                    value = clamped(value + delta, range)
                    repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                        Task { @MainActor in value = clamped(value + delta, range) }
                    }
                }
            }, perform: {})
    }
}

/// 8. Coarse + fine — a normal track, plus a thin second track underneath that only moves the
/// value by a small span around where it is. Precise trims without holding Shift.
struct XCoarseFineSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var fineStart: Double?

    var body: some View {
        VStack(spacing: 6) {
            ControlLabel(title: title, value: String(format: "%.3f", value))
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(uiColors.recessedTrackBackground).frame(height: 6)
                    Capsule().fill(uiColors.accentColor).frame(width: w * fraction(of: value, in: range), height: 6)
                    GlossyThumb().offset(x: w * fraction(of: value, in: range) - 7)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    value = valueAt(fraction: drag.location.x / w, in: range)
                })
            }
            .frame(height: 16)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    HStack(spacing: 0) {
                        ForEach(0..<41, id: \.self) { i in
                            Rectangle()
                                .fill(Color.white.opacity(i % 10 == 0 ? 0.4 : 0.15))
                                .frame(width: 1, height: i % 10 == 0 ? 8 : 4)
                            if i < 40 { Spacer(minLength: 0) }
                        }
                    }
                    Text("fine").font(.system(size: 8)).foregroundStyle(.tertiary).offset(y: 9)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let start = fineStart ?? value
                    fineStart = start
                    let span = (range.upperBound - range.lowerBound) * 0.05
                    value = clamped(start + drag.translation.width / w * span, range)
                }.onEnded { _ in fineStart = nil })
            }
            .frame(height: 18)
        }
    }
}

// MARK: - Gallery

/// All of the above, live, with throwaway local state — embedded in `ComponentGalleryView`'s
/// "Slider Experiments" section.
struct ExperimentalControlsGallery: View {
    @State private var meter = 0.62
    @State private var bipolar = -0.3
    @State private var scrub = 0.35
    @State private var rangeLow = 0.25
    @State private var rangeHigh = 0.7
    @State private var hue = 200.0
    @State private var gauge = 0.55
    @State private var stepper = 0.0
    @State private var fine = 0.123

    private let columns = [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
            specimen("1 · LED Meter") { XMeterSlider(title: "Clarity", value: $meter) }
            specimen("2 · Bipolar Fill (double-click resets)") { XBipolarSlider(title: "Contrast", value: $bipolar) }
            specimen("3 · Scrub Number (drag the number, ⇧ = fine)") { XScrubNumber(title: "Exposure", value: $scrub) }
            specimen("4 · Range (two thumbs)") { XRangeSlider(title: "Luminance Range", low: $rangeLow, high: $rangeHigh) }
            specimen("5 · Hue Loupe (drag to see bubble)") { XHueLoupeSlider(hue: $hue) }
            specimen("6 · Arc Gauge") { XArcGauge(title: "Amount", value: $gauge) }
            specimen("7 · Stepper Pill (hold to repeat)") { XStepperPill(title: "EV", value: $stepper) }
            specimen("8 · Coarse + Fine") { XCoarseFineSlider(title: "Black Lift", value: $fine) }
        }
    }

    private func specimen<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
