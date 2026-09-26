import SwiftUI
import AppKit
import RawEngine

/// Reworks of the sidebar's Chroma / Vibrance / Saturation box, compared in the Developer Mode
/// "Color Intensity Styles" panel. The problem: three controls with near-synonym names that do
/// genuinely different things —
/// - **Chroma** scales every color's intensity by the same factor;
/// - **Vibrance** boosts *muted* colors most, fading out as colors get more saturated (exact
///   kernel math: `c′ = c · (1 + chroma + vib · (1 − c^|vib|))`, `ColorBalanceRGBKernel`);
/// - **Saturation** (Filmic's) blends toward/away from luminance — a separate stage.
/// Each concept tries a different way of making that difference visible, all bound to the real
/// stage fields.

/// The three real bindings, plus Saturation's reset value.
struct ColorIntensityBindings {
    let chroma: Binding<Double>          // −0.5 … 0.5
    let vibrance: Binding<Double>        // −0.5 … 0.5
    let saturation: Binding<Double>      // −100 … 100
    let saturationDefault: Double
}

/// Output chroma for input chroma `c` (0…1): Chroma + Vibrance exactly as the kernel applies them,
/// times an approximate Saturation factor (Filmic's desaturation blend, modeled as a plain scale).
func colorIntensityResponse(_ c: Double, chroma: Double, vibrance: Double, saturation: Double) -> Double {
    let vib = vibrance * (1 - pow(max(c, 0), abs(vibrance)))
    let factor = max(1 + chroma + vib, 0)
    return c * factor * max(1 + saturation / 100, 0)
}

// MARK: - Shared row

/// Bipolar row: fill grows from the center, value on the right in the ±100 scale the rest of the
/// sidebar uses; optional custom track (for photo-colored tracks). Double-click resets.
private struct IntensityRow<Track: View>: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var resetValue: Double = 0
    var displayScale: Double = 200
    @ViewBuilder var track: Track
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(signed(value * displayScale))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
            GeometryReader { geo in
                let w = geo.size.width
                let span = range.upperBound - range.lowerBound
                let zeroX = w * (resetValue - range.lowerBound) / span
                let x = w * (value - range.lowerBound) / span
                ZStack(alignment: .leading) {
                    track.frame(height: 6).clipShape(Capsule())
                    Capsule().fill(uiColors.accentColor.opacity(0.85))
                        .frame(width: abs(x - zeroX), height: 3)
                        .offset(x: min(x, zeroX))
                    Rectangle().fill(Color.white.opacity(0.4)).frame(width: 1, height: 10).offset(x: zeroX - 0.5)
                    Rectangle().fill(.white).frame(width: 9, height: 9).rotationEffect(.degrees(45))
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                        .offset(x: x - 4.5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    value = range.lowerBound + min(max(drag.location.x / w, 0), 1) * span
                })
                .onTapGesture(count: 2) { value = resetValue }
            }
            .frame(height: 14)
        }
    }

    private func signed(_ v: Double) -> String {
        let r = Int(v.rounded())
        return r > 0 ? "+\(r)" : "\(r)"
    }
}

private extension IntensityRow where Track == Color {
    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, resetValue: Double = 0, displayScale: Double = 200, trackColor: Color) {
        self.init(title: title, value: value, range: range, resetValue: resetValue, displayScale: displayScale) { trackColor }
    }
}

// MARK: - 1. Response Curve

/// A graph of what the three controls do together: input color intensity → output intensity.
/// Chroma tilts the line, Vibrance bows its low (muted) end up or down while leaving vivid colors
/// nearly alone, Saturation scales on top. The difference between Chroma and Vibrance, which the
/// names don't explain, becomes a shape.
struct IntensityResponseCurve: View {
    let bindings: ColorIntensityBindings
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Canvas { context, size in
                    let w = size.width, h = size.height
                    context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(uiColors.recessedTrackBackground))
                    // Muted → vivid tint along the bottom so the axis reads as color intensity.
                    context.fill(
                        Path(CGRect(x: 0, y: h - 4, width: w, height: 4)),
                        with: .linearGradient(Gradient(colors: [Color(white: 0.5), Color(hue: 0.05, saturation: 0.85, brightness: 0.9)]),
                                              startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: w, y: 0))
                    )
                    var diagonal = Path()
                    diagonal.move(to: CGPoint(x: 0, y: h)); diagonal.addLine(to: CGPoint(x: w, y: 0))
                    context.stroke(diagonal, with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    var curve = Path()
                    for i in 0...60 {
                        let c = Double(i) / 60
                        let out = colorIntensityResponse(
                            c, chroma: bindings.chroma.wrappedValue, vibrance: bindings.vibrance.wrappedValue,
                            saturation: bindings.saturation.wrappedValue - bindings.saturationDefault
                        )
                        let point = CGPoint(x: w * c, y: h - h * min(out, 1.3) / 1.3)
                        if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                    }
                    context.stroke(curve, with: .color(uiColors.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack {
                    Spacer()
                    HStack {
                        Text("muted").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("vivid").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6).padding(.bottom, 7)
                }
            }
            .frame(height: 110)
            IntensityRow(title: "Chroma", value: bindings.chroma, range: -0.5...0.5, trackColor: uiColors.recessedTrackBackground)
            IntensityRow(title: "Vibrance", value: bindings.vibrance, range: -0.5...0.5, trackColor: uiColors.recessedTrackBackground)
            IntensityRow(title: "Saturation", value: bindings.saturation, range: -100...100,
                         resetValue: bindings.saturationDefault, displayScale: 1, trackColor: uiColors.recessedTrackBackground)
        }
    }
}

// MARK: - 2. Photo-Color Tracks

/// Plain sliders whose tracks are painted in *this photo's* dominant color: Chroma and Saturation
/// run grey → that color at full intensity; Vibrance's track is brightest at its muted end, since
/// that's where it acts. The controls look like the photo they're changing.
struct IntensityPhotoTracks: View {
    let bindings: ColorIntensityBindings
    let photoColor: Color

    var body: some View {
        VStack(spacing: 12) {
            IntensityRow(title: "Chroma", value: bindings.chroma, range: -0.5...0.5) {
                LinearGradient(colors: [Color(white: 0.45), photoColor], startPoint: .leading, endPoint: .trailing)
            }
            IntensityRow(title: "Vibrance", value: bindings.vibrance, range: -0.5...0.5) {
                LinearGradient(colors: [photoColor.opacity(0.9), photoColor.opacity(0.35), Color(white: 0.3)], startPoint: .leading, endPoint: .trailing)
            }
            IntensityRow(title: "Saturation", value: bindings.saturation, range: -100...100,
                         resetValue: bindings.saturationDefault, displayScale: 1) {
                LinearGradient(colors: [Color(white: 0.45), photoColor], startPoint: .leading, endPoint: .trailing)
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(photoColor).frame(width: 12, height: 12)
                Text("Tracks use this photo's dominant color")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - 3. Scope-Linked

/// The three sliders beside a live mini vectorscope of the render — push Chroma and the whole
/// color cloud grows outward; push Vibrance and the muted core swells while the vivid edges barely
/// move. The scope *is* the explanation, and it's the real photo.
struct IntensityScopeLinked: View {
    let bindings: ColorIntensityBindings
    let vectorscope: CGImage?
    /// Slider groove color — defaults to the recessed fill; pass something darker when this sits
    /// inside a recessed box itself (as in the sidebar), or the grooves vanish into it.
    var trackColor: Color? = nil
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(Color.black.opacity(0.45))
                ForEach([0.5, 1.0], id: \.self) { f in
                    Circle().strokeBorder(Color.white.opacity(f == 1 ? 0.18 : 0.07), lineWidth: 1)
                        .frame(width: 104 * f, height: 104 * f)
                }
                if let vectorscope {
                    Image(decorative: vectorscope, scale: 1)
                        .resizable().interpolation(.medium)
                        .blendMode(.plusLighter)
                        .clipShape(Circle())
                }
            }
            .frame(width: 104, height: 104)
            VStack(spacing: 10) {
                IntensityRow(title: "Chroma", value: bindings.chroma, range: -0.5...0.5, trackColor: groove)
                IntensityRow(title: "Vibrance", value: bindings.vibrance, range: -0.5...0.5, trackColor: groove)
                IntensityRow(title: "Saturation", value: bindings.saturation, range: -100...100,
                             resetValue: bindings.saturationDefault, displayScale: 1, trackColor: groove)
            }
        }
    }

    private var groove: Color { trackColor ?? uiColors.recessedTrackBackground }
}

// MARK: - 4. Bipolar Rows

/// The minimal version: three centered-fill rows in the recessed box — direction and amount at a
/// glance, far denser than three knobs, no explanation attempted.
struct IntensityBipolarRows: View {
    let bindings: ColorIntensityBindings
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(spacing: 12) {
            IntensityRow(title: "Chroma", value: bindings.chroma, range: -0.5...0.5, trackColor: Color.black.opacity(0.35))
            IntensityRow(title: "Vibrance", value: bindings.vibrance, range: -0.5...0.5, trackColor: Color.black.opacity(0.35))
            IntensityRow(title: "Saturation", value: bindings.saturation, range: -100...100,
                         resetValue: bindings.saturationDefault, displayScale: 1, trackColor: Color.black.opacity(0.35))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 5. Intensity Pad

/// Vibrance (x) × Saturation (y) as one 2D pad, painted with what the photo's dominant color becomes
/// at each combination — a muted swatch row and a vivid swatch row per cell, so you can see
/// vibrance lifting the muted one far more than the vivid one. Chroma stays a slider underneath.
struct IntensityPad: View {
    let bindings: ColorIntensityBindings
    let photoColor: Color
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let size = geo.size
                let vx = (bindings.vibrance.wrappedValue + 0.5)
                let sy = (bindings.saturation.wrappedValue + 100) / 200
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let cols = 7, rows = 5
                        let cw = size.width / CGFloat(cols), ch = size.height / CGFloat(rows)
                        let base = NSColor(photoColor).usingColorSpace(.deviceRGB) ?? .gray
                        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
                        base.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
                        for col in 0..<cols {
                            for row in 0..<rows {
                                let vib = -0.5 + Double(col) / Double(cols - 1)
                                let satAdj = 100 - Double(row) / Double(rows - 1) * 200
                                let muted = colorIntensityResponse(0.25, chroma: bindings.chroma.wrappedValue, vibrance: vib, saturation: satAdj)
                                let vivid = colorIntensityResponse(0.75, chroma: bindings.chroma.wrappedValue, vibrance: vib, saturation: satAdj)
                                let rect = CGRect(x: CGFloat(col) * cw, y: CGFloat(row) * ch, width: cw, height: ch)
                                context.fill(Path(rect.insetBy(dx: 1, dy: 1).divided(atDistance: ch / 2 - 1, from: .minYEdge).slice),
                                             with: .color(Color(hue: hue, saturation: min(muted, 1), brightness: 0.75)))
                                context.fill(Path(rect.insetBy(dx: 1, dy: 1).divided(atDistance: ch / 2 - 1, from: .minYEdge).remainder),
                                             with: .color(Color(hue: hue, saturation: min(vivid, 1), brightness: 0.75)))
                            }
                        }
                    }
                    .opacity(0.8)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .position(x: size.width * vx, y: size.height * (1 - sy))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    bindings.vibrance.wrappedValue = min(max(drag.location.x / size.width, 0), 1) - 0.5
                    bindings.saturation.wrappedValue = (1 - min(max(drag.location.y / size.height, 0), 1)) * 200 - 100
                })
                .onTapGesture(count: 2) {
                    bindings.vibrance.wrappedValue = 0
                    bindings.saturation.wrappedValue = bindings.saturationDefault
                }
            }
            .frame(height: 130)
            HStack {
                Text("← less vibrance · more →").font(.system(size: 8)).foregroundStyle(.tertiary)
                Spacer()
                Text("↑ saturation").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            IntensityRow(title: "Chroma", value: bindings.chroma, range: -0.5...0.5, trackColor: uiColors.recessedTrackBackground)
        }
    }
}

/// A representative color for the photo, for tinting controls: the render's mean color's hue, pushed
/// to a clearly-colored saturation so even a mostly-neutral photo gives a readable track. Falls back
/// to a warm tone when the mean is too close to grey to have a meaningful hue.
func dominantPhotoColor(_ stats: ImageToneStats) -> Color {
    let color = NSColor(red: CGFloat(stats.meanRed), green: CGFloat(stats.meanGreen), blue: CGFloat(stats.meanBlue), alpha: 1)
    var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
    color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    guard saturation > 0.04 else { return Color(hue: 0.07, saturation: 0.7, brightness: 0.85) }
    return Color(hue: Double(hue), saturation: min(max(Double(saturation) * 3, 0.5), 0.85), brightness: 0.85)
}

// MARK: - Knob layouts: shared pieces

/// Angle convention for the knobs below: degrees clockwise from 12 o'clock.
private func knobPoint(center: CGPoint, radius: CGFloat, degrees: Double) -> CGPoint {
    let radians = degrees * .pi / 180
    return CGPoint(x: center.x + radius * CGFloat(sin(radians)), y: center.y - radius * CGFloat(cos(radians)))
}

private func knobArc(center: CGPoint, radius: CGFloat, from start: Double, to end: Double) -> Path {
    var path = Path()
    let steps = max(2, Int(abs(end - start) / 4))
    for i in 0...steps {
        let point = knobPoint(center: center, radius: radius, degrees: start + (end - start) * Double(i) / Double(steps))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
}

/// Vertical-drag / Shift-fine / double-click-reset behavior shared by the knob variants — same
/// interaction as `KnobControl`.
private struct KnobDrag: ViewModifier {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let resetValue: Double
    @State private var previousY: CGFloat?

    func body(content: Content) -> some View {
        content
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let previous = previousY ?? drag.startLocation.y
                let fine = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1
                let delta = Double(previous - drag.location.y) / 160 * (range.upperBound - range.lowerBound) * fine
                value = min(max(value + delta, range.lowerBound), range.upperBound)
                previousY = drag.location.y
            }.onEnded { _ in previousY = nil })
            .onTapGesture(count: 2) { value = resetValue }
    }
}

private func signedKnobText(_ v: Double) -> String {
    let r = Int(v.rounded())
    return r > 0 ? "+\(r)" : "\(r)"
}

/// A ± knob: faint 270° track, with the value arc growing *from 12 o'clock* toward the value —
/// left for negative, right for positive — so direction reads before the number. Value inside.
struct BipolarKnob: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var resetValue: Double = 0
    var displayScale: Double = 200
    var diameter: CGFloat = 56
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let zeroFraction = (resetValue - range.lowerBound) / (range.upperBound - range.lowerBound)
        let angle = -135 + 270 * fraction
        let zeroAngle = -135 + 270 * zeroFraction
        VStack(spacing: 5) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = size.width / 2 - 4
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)), with: .color(.black.opacity(0.25)))
                context.stroke(knobArc(center: center, radius: r, from: -135, to: 135), with: .color(.white.opacity(0.12)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
                context.stroke(knobArc(center: center, radius: r, from: zeroAngle, to: angle), with: .color(uiColors.accentColor),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
                // Zero tick at the top.
                var tick = Path()
                tick.move(to: knobPoint(center: center, radius: r + 3, degrees: zeroAngle))
                tick.addLine(to: knobPoint(center: center, radius: r - 3, degrees: zeroAngle))
                context.stroke(tick, with: .color(.white.opacity(0.4)), lineWidth: 1)
                let dot = knobPoint(center: center, radius: r, degrees: angle)
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)), with: .color(.white))
            }
            .frame(width: diameter, height: diameter)
            .overlay {
                Text(signedKnobText(value * displayScale))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
            .modifier(KnobDrag(value: $value, range: range, resetValue: resetValue))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A knob whose ring is shaded along its sweep from grey (least intense) to the photo's own color
/// (most intense), with a white indicator — the ring itself says "more of this color that way".
struct TintedRingKnob: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var resetValue: Double = 0
    var displayScale: Double = 200
    let tint: Color
    var diameter: CGFloat = 56

    var body: some View {
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let angle = -135 + 270 * fraction
        VStack(spacing: 5) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = size.width / 2 - 4
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)), with: .color(.black.opacity(0.25)))
                // Manual RGB blend (`Color.mix` is macOS 15+; this app targets 14).
                let tintRGB = NSColor(tint).usingColorSpace(.deviceRGB) ?? .gray
                func blend(_ t: Double) -> Color {
                    let g = 0.4
                    return Color(
                        red: g + (Double(tintRGB.redComponent) - g) * t,
                        green: g + (Double(tintRGB.greenComponent) - g) * t,
                        blue: g + (Double(tintRGB.blueComponent) - g) * t
                    )
                }
                let segments = 36
                for i in 0..<segments {
                    let t0 = Double(i) / Double(segments), t1 = Double(i + 1) / Double(segments)
                    let segment = knobArc(center: center, radius: r, from: -135 + 270 * t0, to: -135 + 270 * t1)
                    let color = blend(t0)
                    context.stroke(segment, with: .color(color.opacity(t0 <= fraction ? 1 : 0.35)),
                                   style: StrokeStyle(lineWidth: 4, lineCap: .butt))
                }
                let dot = knobPoint(center: center, radius: r, degrees: angle)
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 4.5, y: dot.y - 4.5, width: 9, height: 9)), with: .color(.white))
            }
            .frame(width: diameter, height: diameter)
            .overlay {
                Text(signedKnobText(value * displayScale))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
            .modifier(KnobDrag(value: $value, range: range, resetValue: resetValue))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Live vectorscope of the render, as a plain circle.
private struct MiniVectorscope: View {
    let image: CGImage?
    var diameter: CGFloat = 110

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.45))
            ForEach([0.5, 1.0], id: \.self) { f in
                Circle().strokeBorder(Color.white.opacity(f == 1 ? 0.18 : 0.07), lineWidth: 1)
                    .frame(width: diameter * f, height: diameter * f)
            }
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                    .blendMode(.plusLighter).clipShape(Circle())
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The muted → vivid response graph (see `IntensityResponseCurve`), on its own.
private struct IntensityResponseGraph: View {
    let bindings: ColorIntensityBindings
    var height: CGFloat = 90
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        ZStack {
            Canvas { context, size in
                let w = size.width, h = size.height
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(uiColors.recessedTrackBackground))
                var diagonal = Path()
                diagonal.move(to: CGPoint(x: 0, y: h)); diagonal.addLine(to: CGPoint(x: w, y: 0))
                context.stroke(diagonal, with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var curve = Path()
                for i in 0...60 {
                    let c = Double(i) / 60
                    let out = colorIntensityResponse(
                        c, chroma: bindings.chroma.wrappedValue, vibrance: bindings.vibrance.wrappedValue,
                        saturation: bindings.saturation.wrappedValue - bindings.saturationDefault
                    )
                    let point = CGPoint(x: w * c, y: h - h * min(out, 1.3) / 1.3)
                    if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(uiColors.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack {
                Spacer()
                HStack {
                    Text("muted").font(.system(size: 8)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("vivid").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6).padding(.bottom, 5)
            }
        }
        .frame(height: height)
    }
}

/// Before → after for the photo's own color at two intensities (a muted and a vivid version) —
/// the whole Chroma-vs-Vibrance distinction in four swatches: Vibrance changes the muted row far
/// more than the vivid one; Chroma changes both alike.
private struct IntensitySwatches: View {
    let bindings: ColorIntensityBindings
    let photoColor: Color

    var body: some View {
        let base = NSColor(photoColor).usingColorSpace(.deviceRGB) ?? .gray
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
        base.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
        return VStack(spacing: 6) {
            row("Muted colors", hue: Double(hue), input: 0.3)
            row("Vivid colors", hue: Double(hue), input: 0.75)
        }
    }

    private func row(_ label: String, hue: Double, input: Double) -> some View {
        let output = colorIntensityResponse(
            input, chroma: bindings.chroma.wrappedValue, vibrance: bindings.vibrance.wrappedValue,
            saturation: bindings.saturation.wrappedValue - bindings.saturationDefault
        )
        return HStack(spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            RoundedRectangle(cornerRadius: 4).fill(Color(hue: hue, saturation: input, brightness: 0.78))
                .frame(height: 22)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            RoundedRectangle(cornerRadius: 4).fill(Color(hue: hue, saturation: min(output, 1), brightness: 0.78))
                .frame(height: 22)
        }
    }
}

// MARK: - Knob layouts

/// Visualization on top, three rotary knobs below — the four combinations compared in the dev
/// panel's "Color Intensity Knob Layouts".
struct IntensityKnobLayout: View {
    enum Style { case scopeBipolar, curveBipolar, swatchesTinted, scopeClassic }

    let style: Style
    let bindings: ColorIntensityBindings
    let vectorscope: CGImage?
    let photoColor: Color
    /// `false` drops the top visualization and keeps just the knobs (the sidebar's current use).
    var showsVisualization = true

    var body: some View {
        VStack(spacing: 14) {
            if showsVisualization {
            switch style {
            case .scopeBipolar, .scopeClassic:
                MiniVectorscope(image: vectorscope).frame(maxWidth: .infinity)
            case .curveBipolar:
                IntensityResponseGraph(bindings: bindings)
            case .swatchesTinted:
                IntensitySwatches(bindings: bindings, photoColor: photoColor)
            }
            }
            HStack(alignment: .top, spacing: 0) {
                knob("Chroma", bindings.chroma, -0.5...0.5, 0, 200)
                knob("Vibrance", bindings.vibrance, -0.5...0.5, 0, 200)
                knob("Saturation", bindings.saturation, -100...100, bindings.saturationDefault, 1)
            }
        }
    }

    @ViewBuilder
    private func knob(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ reset: Double, _ scale: Double) -> some View {
        switch style {
        case .scopeBipolar, .curveBipolar:
            BipolarKnob(title: title, value: value, range: range, resetValue: reset, displayScale: scale)
        case .swatchesTinted:
            TintedRingKnob(title: title, value: value, range: range, resetValue: reset, displayScale: scale, tint: photoColor)
        case .scopeClassic:
            VStack(spacing: 6) {
                KnobControl(value: value, range: range, resetValue: reset)
                    .overlay {
                        Text(signedKnobText(value.wrappedValue * scale))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
