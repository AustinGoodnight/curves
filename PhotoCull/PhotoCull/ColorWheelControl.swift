import AppKit
import SwiftUI

/// A color wheel: drag position encodes hue (angle) + chroma (radius), with a curved slider
/// hugging the wheel's right edge for the zone's luminance lift (Final Cut Pro's color-wheel
/// convention — see the "Luminance arc" section below). The reset button (or a double-click/
/// double-tap on the wheel *or* the arc) returns hue, chroma, and luminance to neutral. Holding
/// Shift while dragging either the puck or the arc switches to relative fine movement at
/// `fineFactor` sensitivity, computed from the previous drag event — see `MinimalSlider`'s doc
/// comment for why (same technique, applied to 2D cartesian deltas for the puck and 1D angular
/// deltas for the arc instead of a 1D fraction).
///
/// `maxChroma` calibrates how much chroma the wheel's outer edge represents. This is *not* the
/// parameter's hard range (0...1, per `dt_iop_colorbalancergb_params_t`) — darktable's own GUI
/// restricts each zone's slider to a much smaller "soft range" for normal dragging
/// (`dt_bauhaus_slider_set_soft_range` in `colorbalancergb.c`: global 0...0.01, shadows 0...0.5,
/// midtones 0...0.1, highlights 0...0.2), because this module's color math is sensitive enough
/// that the full 0...1 range is only reachable by typing a value in, not by dragging. Mapping
/// the wheel's edge to 1.0 made small drags produce wildly oversaturated results — this
/// reproduces darktable's own per-zone calibration instead.
struct ColorWheelControl: View {
    let title: String
    @Binding var hue: Double        // degrees, 0...360
    @Binding var chroma: Double     // 0...maxChroma
    @Binding var luminance: Double
    var maxChroma: Double = 0.5
    var luminanceRange: ClosedRange<Double> = -1...1
    var diameter: CGFloat = 92
    var onChange: () -> Void = {}

    @State private var previousPuckLocation: CGPoint? = nil
    @State private var previousArcTheta: Double? = nil
    @Environment(ColorSchemeStore.self) private var uiColors
    private let fineFactor: CGFloat = 0.2

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset \(title)")
                .disabled(hue == 0 && chroma == 0 && luminance == 0)
            }

            ZStack {
                // Hit region for the luminance arc — a padded band following the arc's own curve,
                // not a full circle. A full circle (the previous approach) reached well past the
                // visible arc on every side, and once wheels sit close together that invisible
                // region bled into the *next* wheel's puck, capturing drags meant for it instead.
                // This shape only covers the ring the arc actually occupies, with a little slack
                // for easy grabbing, so it can't extend into a neighboring wheel.
                // `.simultaneousGesture`, not `.onTapGesture` — see `MinimalSlider`'s doc comment
                // for why an exclusive tap recognizer never sees a double-click when a zero-
                // `minimumDistance` `DragGesture` is already attached to the same view.
                arcHitPath
                    .fill(Color.white.opacity(0.001))
                    .gesture(arcDragGesture)
                    .simultaneousGesture(TapGesture(count: 2).onEnded(reset))

                arcTrack
                arcFill

                ZStack {
                    Circle()
                        .fill(AngularGradient(gradient: Self.hueSpectrum, center: .center))
                        .overlay(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: diameter / 2))

                    Circle()
                        .fill(Color.primary.opacity(0.4))
                        .frame(width: 3, height: 3)

                    Circle()
                        .fill(Color.white)
                        .frame(width: puckDiameter, height: puckDiameter)
                        .shadow(radius: 1)
                        .offset(puckOffset)
                        .allowsHitTesting(false)
                }
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .gesture(dragGesture)
                .simultaneousGesture(TapGesture(count: 2).onEnded(reset))

                arcThumb
                    .allowsHitTesting(false)
            }
            .frame(width: containerSize, height: containerSize)
            // A plain `.overlay` rather than a shared `ZStack(alignment:)` — the arc `Path`
            // shapes above render correctly only under this `ZStack`'s *default* `.center`
            // alignment (their own drawn coordinates already assume that placement); changing
            // the container's alignment to position this label shifted every arc/thumb along
            // with it. Overlaying keeps the label's alignment independent of theirs.
            .overlay(alignment: .bottomLeading) {
                // The arc only ever occupies the container's right side (-85°...85°, i.e. the
                // wheel's right half) — the bottom-left corner outside the circle is otherwise
                // dead space, so the value reads there instead of costing its own row below the
                // whole control.
                Text(luminance, format: .number.precision(.fractionLength(2)))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Luminance arc
    //
    // A curved slider hugging the wheel's right edge (Final Cut's color-wheel convention),
    // replacing what used to be a straight vertical slider beside the wheel. Every point is
    // plotted directly from the arc's own center + radius (`arcPoint(angleDegrees:)`) rather
    // than expressed as an SVG/CoreGraphics arc-segment command — the two-flags-pick-one-of-4-
    // possible-circles ambiguity in those APIs is exactly what produced a track/thumb that didn't
    // align to the same curve in an earlier pass at this. Plotting points directly sidesteps it.
    //
    // Angle convention (independent of the wheel's own hue angle convention above): 0° is the
    // rightmost point (3 o'clock), increasing clockwise. The arc spans -85...85°, i.e. nearly
    // the wheel's full height, leaving a small gap at top and bottom. Value 0 (or the range's
    // minimum, if it doesn't span 0) sits at 0°/rightmost; the range's maximum is at -85° (top);
    // the minimum at +85° (bottom) — "up is more," matching every other slider in the editor.

    private var arcRadius: CGFloat { diameter / 2 + 16 }
    private var containerSize: CGFloat { 2 * (arcRadius + 10) }
    private let arcAngleLimit: Double = 85

    private func arcPoint(angleDegrees: Double, radius: CGFloat? = nil) -> CGPoint {
        let rad: Double = angleDegrees * Double.pi / 180
        let center = containerSize / 2
        let r = radius ?? arcRadius
        let x = center + r * CGFloat(cos(rad))
        let y = center + r * CGFloat(sin(rad))
        return CGPoint(x: x, y: y)
    }

    private func arcAngle(forFraction fraction: Double) -> Double {
        arcAngleLimit - fraction * (2 * arcAngleLimit)
    }

    private func luminanceFraction(_ value: Double) -> Double {
        let span = luminanceRange.upperBound - luminanceRange.lowerBound
        guard span > 0 else { return 0 }
        return (value - luminanceRange.lowerBound) / span
    }

    private func arcPath(fromAngle: Double, toAngle: Double) -> Path {
        Path { path in
            let steps = 20
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let angle = fromAngle + (toAngle - fromAngle) * t
                let p = arcPoint(angleDegrees: angle)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
    }

    /// A padded annular wedge around the visible arc — outer edge a bit past the track, inner
    /// edge a bit past the puck, angular span a bit past `arcAngleLimit` on each end — used only
    /// as `arcDragGesture`'s hit region (see the doc comment where it's applied). Built from the
    /// same `arcPoint(angleDegrees:radius:)` line-segment approach as `arcPath` rather than
    /// `Path.addArc`, for the same reason noted on `arcPath`: consistent, predictable geometry.
    private var arcHitPath: Path {
        let pad: Double = 6
        let outerRadius = arcRadius + 14
        let innerRadius = diameter / 2 + 2
        let steps = 20
        return Path { path in
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let angle = -arcAngleLimit - pad + t * (2 * (arcAngleLimit + pad))
                let p = arcPoint(angleDegrees: angle, radius: outerRadius)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let angle = arcAngleLimit + pad - t * (2 * (arcAngleLimit + pad))
                path.addLine(to: arcPoint(angleDegrees: angle, radius: innerRadius))
            }
            path.closeSubpath()
        }
    }

    private var arcTrack: some View {
        arcPath(fromAngle: -arcAngleLimit, toAngle: arcAngleLimit)
            .stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 6, lineCap: .round))
    }

    private var arcFill: some View {
        let zeroFraction = luminanceFraction(max(luminanceRange.lowerBound, min(0, luminanceRange.upperBound)))
        let valueFraction = luminanceFraction(luminance)
        return arcPath(fromAngle: arcAngle(forFraction: zeroFraction), toAngle: arcAngle(forFraction: valueFraction))
            .stroke(uiColors.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
    }

    private var arcThumb: some View {
        let p = arcPoint(angleDegrees: arcAngle(forFraction: luminanceFraction(luminance)))
        return Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .shadow(radius: 1)
            .position(p)
    }

    private var arcDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let center = containerSize / 2
                let dx: Double = Double(drag.location.x - center)
                let dy: Double = Double(drag.location.y - center)
                let theta = min(max(atan2(dy, dx) * 180 / Double.pi, -arcAngleLimit), arcAngleLimit)

                if NSEvent.modifierFlags.contains(.shift), let previousArcTheta {
                    // Same theta → fraction relationship as the absolute branch below, applied as
                    // a delta from the previous event instead of an absolute position.
                    let deltaFraction = ((previousArcTheta - theta) / (2 * arcAngleLimit)) * Double(fineFactor)
                    let newFraction = min(max(luminanceFraction(luminance) + deltaFraction, 0), 1)
                    luminance = luminanceRange.lowerBound + newFraction * (luminanceRange.upperBound - luminanceRange.lowerBound)
                } else {
                    let fraction = (arcAngleLimit - theta) / (2 * arcAngleLimit)
                    luminance = luminanceRange.lowerBound + fraction * (luminanceRange.upperBound - luminanceRange.lowerBound)
                }
                previousArcTheta = theta
                onChange()
            }
            .onEnded { _ in previousArcTheta = nil }
    }

    private func reset() {
        hue = 0
        chroma = 0
        luminance = 0
        onChange()
    }

    private var puckDiameter: CGFloat {
        max(9, diameter * 0.12)
    }

    /// Fraction of the wheel's radius the current chroma represents, given this zone's calibrated max.
    private var radiusFraction: CGFloat {
        guard maxChroma > 0 else { return 0 }
        return CGFloat(min(max(chroma / maxChroma, 0), 1))
    }

    private var puckOffset: CGSize {
        let radius = radiusFraction * (diameter / 2)
        let mathAngle = (90 - hue) * .pi / 180
        return CGSize(width: radius * cos(mathAngle), height: -radius * sin(mathAngle))
    }

    /// Shared by both branches of `dragGesture` — takes a position in the same cartesian space as
    /// `puckOffset` (center-relative points) and writes the `hue`/`chroma` it corresponds to.
    private func applyPuckPosition(_ cartesian: CGSize) {
        let r = (cartesian.width * cartesian.width + cartesian.height * cartesian.height).squareRoot()
        let clampedR = min(r, diameter / 2)
        let theta = atan2(-cartesian.height, cartesian.width)
        var newHue = 90 - theta * 180 / .pi
        if newHue < 0 { newHue += 360 }
        if newHue >= 360 { newHue -= 360 }
        hue = newHue
        chroma = Double(clampedR / (diameter / 2)) * maxChroma
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let center = CGPoint(x: diameter / 2, y: diameter / 2)

                if NSEvent.modifierFlags.contains(.shift), let previousPuckLocation {
                    // `puckOffset` is the puck's current cartesian position (center-relative);
                    // nudge it by the scaled-down delta rather than jumping to the raw cursor.
                    let current = puckOffset
                    let delta = CGSize(
                        width: (value.location.x - previousPuckLocation.x) * fineFactor,
                        height: (value.location.y - previousPuckLocation.y) * fineFactor
                    )
                    applyPuckPosition(CGSize(width: current.width + delta.width, height: current.height + delta.height))
                } else {
                    applyPuckPosition(CGSize(width: value.location.x - center.x, height: value.location.y - center.y))
                }
                previousPuckLocation = value.location
                onChange()
            }
            .onEnded { _ in previousPuckLocation = nil }
    }

    private static let hueSpectrum = Gradient(colors: stride(from: 0.0, through: 360.0, by: 30.0).map {
        Color(hue: $0 / 360.0, saturation: 1, brightness: 1)
    })
}
