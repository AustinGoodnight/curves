import AppKit
import SwiftUI

/// White Balance controls in the same direction as the color wheels' `ColorWheelStyle`: dark
/// recessed surfaces, color only where it carries meaning, every color at one OKLCH lightness,
/// and this photo's as-shot value always marked (the old gradient faders put their grey "neutral"
/// at a fixed spot regardless of what the camera recorded). Two layouts, picked in Settings >
/// White Balance Control: `WhiteBalanceFaderPair` (Temp/Tint stripe faders) and
/// `WhiteBalancePad` (one 2D pad whose edges carry the same stripes as its axes).

/// The four direction colors, at the wheel ring's lightness. OKLCH hues: amber ≈ 70°, blue ≈ 250°
/// (warm/cool), magenta ≈ 330°, green ≈ 145°.
enum WhiteBalancePalette {
    static let warm = WheelPalette.oklch(hueDegrees: 70)
    static let cool = WheelPalette.oklch(hueDegrees: 250)
    static let magenta = WheelPalette.oklch(hueDegrees: 330)
    static let green = WheelPalette.oklch(hueDegrees: 145)
    static let neutral = Color(white: 0.55)
}

private func signed(_ value: Double, suffix: String) -> String {
    let rounded = Int(value.rounded())
    return (rounded > 0 ? "+\(rounded)" : "\(rounded)") + suffix
}

/// The shared small outlined control dot (curves, wheels' arcs, faders) — accent + larger mid-drag.
private struct ControlDot: View {
    var isActive: Bool
    var fill: Color = .white
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        Circle()
            .fill(isActive ? uiColors.accentColor : fill)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
            .frame(width: isActive ? 11 : 8, height: isActive ? 11 : 8)
    }
}

// MARK: - Stripe faders

/// A vertical WB fader on a dark track, with a thin color stripe running low-end color → neutral
/// grey at *this photo's* as-shot mark → high-end color.
struct WhiteBalanceFader: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// This photo's as-shot value — the stripe's neutral point, the tick, and the reset.
    let neutral: Double
    let lowColor: Color
    let highColor: Color

    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var previousDragY: CGFloat?

    private let trackWidth: CGFloat = 18
    private let fineFactor: CGFloat = 0.2

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let valueY = (1 - fraction(value)) * height
            let neutralY = (1 - fraction(neutral)) * height
            let isDragging = previousDragY != nil

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: trackWidth / 2)
                    .fill(uiColors.recessedTrackBackground)
                    .overlay(RoundedRectangle(cornerRadius: trackWidth / 2).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                Capsule()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: lowColor, location: 0),
                            .init(color: WhiteBalancePalette.neutral, location: fraction(neutral)),
                            .init(color: highColor, location: 1),
                        ],
                        startPoint: .bottom, endPoint: .top
                    ))
                    .frame(width: 4, height: height - 8)
                    .offset(y: 4)
                // As-shot mark.
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: trackWidth - 4, height: 1)
                    .offset(y: neutralY - 0.5)
                ControlDot(isActive: isDragging)
                    .offset(y: valueY - (isDragging ? 5.5 : 4))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if NSEvent.modifierFlags.contains(.shift), let previousDragY {
                            setFraction(fraction(value) + ((previousDragY - drag.location.y) / height) * fineFactor)
                        } else {
                            setFraction(1 - drag.location.y / height)
                        }
                        previousDragY = drag.location.y
                    }
                    .onEnded { _ in previousDragY = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = neutral })
        }
        .frame(width: trackWidth)
    }

    private func fraction(_ v: Double) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func setFraction(_ f: CGFloat) {
        value = range.lowerBound + Double(min(max(f, 0), 1)) * (range.upperBound - range.lowerBound)
    }
}

/// Temp + Tint `WhiteBalanceFader` columns with titles and value pills, laid out like the old
/// `verticalGradientSlider` pair so it drops into the same slot. Under each absolute value, the
/// change *relative to as-shot* ("+450K", "−6") — the number that says how much correction is on.
struct WhiteBalanceFaderPair: View {
    @Binding var temperature: Double
    @Binding var tint: Double
    let axes: WhiteBalanceAxes
    /// Same as `WhiteBalancePad.slotHeight` — centers each fader in a slot this tall.
    var slotHeight: CGFloat? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            column("Temp", absolute: "\(Int(temperature.rounded()))K", relative: signed(temperature - axes.defaultTemperature, suffix: "K")) {
                WhiteBalanceFader(
                    value: $temperature, range: axes.temperatureRange, neutral: axes.defaultTemperature,
                    lowColor: WhiteBalancePalette.cool, highColor: WhiteBalancePalette.warm
                )
            }
            column("Tint", absolute: signed(tint, suffix: ""), relative: signed(tint - axes.defaultTint, suffix: "")) {
                WhiteBalanceFader(
                    value: $tint, range: axes.tintRange, neutral: axes.defaultTint,
                    lowColor: WhiteBalancePalette.green, highColor: WhiteBalancePalette.magenta
                )
            }
        }
    }

    private func column<Fader: View>(_ title: String, absolute: String, relative: String, @ViewBuilder fader: () -> Fader) -> some View {
        VStack(spacing: controlSubtitleSpacing) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(height: controlSubtitleHeight)
            fader()
                .frame(height: colorFaderTrackHeight)
                .frame(height: slotHeight ?? colorFaderTrackHeight)
            VStack(spacing: 1) {
                Text(absolute).font(.caption)
                Text(relative).font(.caption2).foregroundStyle(.tertiary)
            }
            .monospacedDigit()
            .fixedSize()
        }
        .frame(width: faderColumnWidth)
    }
}

// MARK: - Pads

/// Ranges + as-shot values both WB layouts need.
struct WhiteBalanceAxes {
    var temperatureRange: ClosedRange<Double> = 2000...12000
    var tintRange: ClosedRange<Double> = -150...150
    var defaultTemperature: Double
    var defaultTint: Double
}

/// A single 2D White Balance pad: Tint runs horizontally (green → magenta), Temp vertically
/// (cool → warm), mapped linearly over the full ranges. The stripe faders' own stripes run along
/// its left (Temp) and bottom (Tint) edges as axes, each turning neutral at the as-shot crosshair,
/// with a white tick where the puck currently projects onto each. Those edges are also sliders:
/// a drag that *starts* within `edgeGrab` of the left edge moves Temp only, of the bottom edge
/// Tint only (double-click there resets just that axis); anywhere else moves both.
struct WhiteBalancePad: View {
    private enum Axis { case both, temperature, tint }

    @Binding var temperature: Double
    @Binding var tint: Double
    let axes: WhiteBalanceAxes
    var size: CGFloat = colorFaderTrackHeight
    /// When set, the pad is centered in a slot this tall instead of hugging its own `size` — how
    /// `ColorBalanceBarView` lines the pad's center up with the color wheels' next to it.
    var slotHeight: CGFloat? = nil

    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var previousDragLocation: CGPoint?
    /// The axis the current drag is locked to, decided once from where it started.
    @State private var dragAxis: Axis?
    @State private var hoverAxis: Axis = .both
    private let band: CGFloat = 4
    /// How far in from the left/bottom edge a drag counts as grabbing that axis's stripe.
    private let edgeGrab: CGFloat = 14

    var body: some View {
        VStack(spacing: controlSubtitleSpacing) {
            Text("White Balance").font(.caption).foregroundStyle(.secondary).fixedSize()
                .frame(height: controlSubtitleHeight)
            pad
                .frame(height: slotHeight ?? size)
            HStack(spacing: 8) {
                Text("\(Int(temperature.rounded()))K")
                Text(signed(tint, suffix: ""))
                Text("\(signed(temperature - axes.defaultTemperature, suffix: "K")) · \(signed(tint - axes.defaultTint, suffix: ""))")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .monospacedDigit()
            .fixedSize()
        }
    }

    private func fraction(_ value: Double, in range: ClosedRange<Double>) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func point(temperature: Double, tint: Double) -> CGPoint {
        CGPoint(
            x: fraction(tint, in: axes.tintRange) * size,
            y: (1 - fraction(temperature, in: axes.temperatureRange)) * size
        )
    }

    private func apply(_ p: CGPoint) {
        let tf = Double(min(max(p.x / size, 0), 1)), pf = Double(min(max(1 - p.y / size, 0), 1))
        temperature = axes.temperatureRange.lowerBound + pf * (axes.temperatureRange.upperBound - axes.temperatureRange.lowerBound)
        tint = axes.tintRange.lowerBound + tf * (axes.tintRange.upperBound - axes.tintRange.lowerBound)
    }

    private func axis(at p: CGPoint) -> Axis {
        let fromLeft = p.x, fromBottom = size - p.y
        switch (fromLeft < edgeGrab, fromBottom < edgeGrab) {
        case (true, true): return fromLeft < fromBottom ? .temperature : .tint
        case (true, false): return .temperature
        case (false, true): return .tint
        case (false, false): return .both
        }
    }

    private var pad: some View {
        let puck = point(temperature: temperature, tint: tint)
        let center = point(temperature: axes.defaultTemperature, tint: axes.defaultTint)
        let isMoved = abs(puck.x - center.x) > 0.5 || abs(puck.y - center.y) > 0.5

        return ZStack {
            uiColors.recessedTrackBackground
            Path { path in
                path.move(to: CGPoint(x: center.x, y: 0)); path.addLine(to: CGPoint(x: center.x, y: size))
                path.move(to: CGPoint(x: 0, y: center.y)); path.addLine(to: CGPoint(x: size, y: center.y))
            }
            .stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            stripeAxes(center: center, puck: puck, highlighted: dragAxis ?? hoverAxis)
            if isMoved {
                Path { path in path.move(to: center); path.addLine(to: puck) }
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            }
            ControlDot(isActive: previousDragLocation != nil)
                .position(puck)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let locked = dragAxis ?? axis(at: drag.startLocation)
                    dragAxis = locked
                    var target = drag.location
                    if NSEvent.modifierFlags.contains(.shift), let previousDragLocation {
                        target = CGPoint(
                            x: puck.x + (drag.location.x - previousDragLocation.x) * 0.2,
                            y: puck.y + (drag.location.y - previousDragLocation.y) * 0.2
                        )
                    }
                    switch locked {
                    case .both: break
                    case .temperature: target.x = puck.x
                    case .tint: target.y = puck.y
                    }
                    apply(target)
                    previousDragLocation = drag.location
                }
                .onEnded { _ in
                    previousDragLocation = nil
                    dragAxis = nil
                }
        )
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
            let tapped = axis(at: tap.location)
            if tapped != .tint { temperature = axes.defaultTemperature }
            if tapped != .temperature { tint = axes.defaultTint }
        })
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverAxis = axis(at: location)
                switch hoverAxis {
                case .temperature: NSCursor.resizeUpDown.set()
                case .tint: NSCursor.resizeLeftRight.set()
                case .both: NSCursor.arrow.set()
                }
            case .ended:
                hoverAxis = .both
                NSCursor.arrow.set()
            }
        }
    }

    /// `highlighted` (hovered or being dragged) thickens that axis's stripe so the edge reads as
    /// the slider it is.
    private func stripeAxes(center: CGPoint, puck: CGPoint, highlighted: Axis) -> some View {
        let temperatureBand = highlighted == .temperature ? band + 3 : band
        let tintBand = highlighted == .tint ? band + 3 : band
        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: WhiteBalancePalette.cool, location: 0),
                    .init(color: WhiteBalancePalette.neutral, location: 1 - center.y / size),
                    .init(color: WhiteBalancePalette.warm, location: 1),
                ],
                startPoint: .bottom, endPoint: .top
            )
            .frame(width: temperatureBand)
            .frame(maxWidth: .infinity, alignment: .leading)
            LinearGradient(
                stops: [
                    .init(color: WhiteBalancePalette.green, location: 0),
                    .init(color: WhiteBalancePalette.neutral, location: center.x / size),
                    .init(color: WhiteBalancePalette.magenta, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: tintBand)
            .frame(maxHeight: .infinity, alignment: .bottom)
            Rectangle().fill(Color.white).frame(width: temperatureBand + 6, height: 1.5).position(x: (temperatureBand + 6) / 2, y: puck.y)
            Rectangle().fill(Color.white).frame(width: 1.5, height: tintBand + 6).position(x: puck.x, y: size - (tintBand + 6) / 2)
        }
        .animation(.easeOut(duration: 0.12), value: highlighted)
        .allowsHitTesting(false)
    }
}
