import AppKit
import SwiftUI

/// A single 2D pad replacing the Temp/Tint pair of `VerticalGradientSlider`s — Tint on the
/// horizontal axis (left = green, right = magenta, matching `Gradient.neutralTint`'s own
/// left-to-right sense), Temp on the vertical axis (bottom = cool/blue, top = warm/orange,
/// matching `VerticalGradientSlider`'s own bottom-to-top sense for the same parameter so dragging
/// this pad "up" means the same thing dragging that fader "up" always has). One dot encodes both
/// values at once instead of two independent tracks — an alternate style, chosen via
/// `WhiteBalanceControlStyle` in Settings, not a replacement for the classic faders.
///
/// The background approximates a 2D color gradient (SwiftUI has no native two-axis gradient on
/// this deployment target — `MeshGradient` is macOS 15+, this project targets 14) by layering two
/// `LinearGradient`s, each faded to `.clear` at its own midpoint, over a flat neutral base. Faded-
/// to-clear (rather than the fully opaque 3-stop gradients `VerticalGradientSlider` uses) is what
/// lets both axes read at once without one blend mode fighting the other for saturation.
struct XYWhiteBalanceControl: View {
    @Binding var temperature: Double
    @Binding var tint: Double
    let temperatureRange: ClosedRange<Double>
    let tintRange: ClosedRange<Double>
    let defaultTemperature: Double
    let defaultTint: Double
    // Not `colorFaderTrackHeight - 26` (the wheel-diameter formula in `EditorView.wheelDiameter`)
    // — that formula compensates for the wheel's own 26pt top/bottom margin (empty space around
    // the circle, reserved for the luminance arc) so the *circle's* bottom, not the wheel view's
    // outer frame, lands at `colorFaderTrackHeight`. This pad has no such margin — it fills its
    // frame edge to edge — so using the full `colorFaderTrackHeight` directly is what actually
    // lands its bottom at the same y as the wheels' circles and the classic faders' tracks, all
    // of which sit `colorFaderTrackHeight` below the shared title row.
    var size: CGFloat = colorFaderTrackHeight

    @State private var previousDragLocation: CGPoint? = nil
    private let fineFactor: CGFloat = 0.2
    /// Interior grid lines per axis (3 lines → quarters), plus a dashed crosshair at the neutral
    /// default position drawn separately in `defaultCrosshair` — matches `ColorWheelControl`'s
    /// dashed-reference-line weight (`Color.white.opacity(0.25)`-ish) rather than the plain grid's.
    private let gridDivisions = 4

    var body: some View {
        ZStack {
            background
            grid
            defaultCrosshair
            dot
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .gesture(dragGesture)
        // `.simultaneousGesture`, not `.onTapGesture` — see `MinimalSlider`'s doc comment for why
        // an exclusive tap recognizer never sees a double-click when a zero-`minimumDistance`
        // `DragGesture` is already attached to the same view.
        .simultaneousGesture(TapGesture(count: 2).onEnded(reset))
    }

    /// Endpoint colors are `.normalizedVividness()`'d the same as every other spectrum control in
    /// the bottom bar (see `Color.controlSpectrumSaturation`'s doc comment) — this pad additionally
    /// fades each to `.clear` at 65% opacity (see `background`'s own doc comment above) so the
    /// vividness match happens on the colors going *into* that fade, not after it.
    private var background: some View {
        ZStack {
            Color(red: 154 / 255, green: 154 / 255, blue: 154 / 255)
            LinearGradient(
                stops: [
                    .init(color: Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255).normalizedVividness().opacity(0.65), location: 0),
                    .init(color: .clear, location: 0.5),
                    .init(color: Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255).normalizedVividness().opacity(0.65), location: 1),
                ],
                startPoint: .bottom, endPoint: .top
            )
            LinearGradient(
                stops: [
                    .init(color: Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255).normalizedVividness().opacity(0.65), location: 0),
                    .init(color: .clear, location: 0.5),
                    .init(color: Color(red: 255 / 255, green: 45 / 255, blue: 210 / 255).normalizedVividness().opacity(0.65), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    private var grid: some View {
        Canvas { context, canvasSize in
            var path = Path()
            for i in 1..<gridDivisions {
                let f = CGFloat(i) / CGFloat(gridDivisions)
                path.move(to: CGPoint(x: f * canvasSize.width, y: 0))
                path.addLine(to: CGPoint(x: f * canvasSize.width, y: canvasSize.height))
                path.move(to: CGPoint(x: 0, y: f * canvasSize.height))
                path.addLine(to: CGPoint(x: canvasSize.width, y: f * canvasSize.height))
            }
            context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// Dashed crosshair marking the neutral (as-shot default) position, distinct from the plain
    /// interior grid lines above — same purpose as `ColorWheelControl.arcTrack`'s and
    /// `CurveEditorControl.referenceLines`' dashed reference lines: showing at a glance how far a
    /// drag has moved from "no correction" rather than requiring a read of the value pills.
    private var defaultCrosshair: some View {
        Canvas { context, canvasSize in
            let x = fraction(defaultTint, in: tintRange) * canvasSize.width
            let y = (1 - fraction(defaultTemperature, in: temperatureRange)) * canvasSize.height
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: canvasSize.height))
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: canvasSize.width, y: y))
            context.stroke(path, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .allowsHitTesting(false)
    }

    private var dot: some View {
        let x = fraction(tint, in: tintRange) * size
        let y = (1 - fraction(temperature, in: temperatureRange)) * size
        return Circle()
            .fill(Color.white)
            .frame(width: 16, height: 16)
            .shadow(radius: 1)
            .position(x: x, y: y)
            .allowsHitTesting(false)
    }

    private func fraction(_ value: Double, in range: ClosedRange<Double>) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func applyFractions(tintFraction: CGFloat, temperatureFraction: CGFloat) {
        let tf = min(max(tintFraction, 0), 1)
        let pf = min(max(temperatureFraction, 0), 1)
        tint = tintRange.lowerBound + Double(tf) * (tintRange.upperBound - tintRange.lowerBound)
        temperature = temperatureRange.lowerBound + Double(pf) * (temperatureRange.upperBound - temperatureRange.lowerBound)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if NSEvent.modifierFlags.contains(.shift), let previousDragLocation {
                    let deltaTintFraction = ((drag.location.x - previousDragLocation.x) / size) * fineFactor
                    let deltaTempFraction = ((previousDragLocation.y - drag.location.y) / size) * fineFactor
                    applyFractions(
                        tintFraction: fraction(tint, in: tintRange) + deltaTintFraction,
                        temperatureFraction: fraction(temperature, in: temperatureRange) + deltaTempFraction
                    )
                } else {
                    applyFractions(
                        tintFraction: drag.location.x / size,
                        temperatureFraction: 1 - drag.location.y / size
                    )
                }
                previousDragLocation = drag.location
            }
            .onEnded { _ in previousDragLocation = nil }
    }

    private func reset() {
        temperature = defaultTemperature
        tint = defaultTint
    }
}
