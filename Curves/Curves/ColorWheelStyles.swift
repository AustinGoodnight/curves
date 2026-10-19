import SwiftUI
import RawEngine

/// Candidate faces for `ColorWheelControl`, compared in the bottom bar via Developer Mode's
/// "Wheel Style" menu (and side by side in the Component Gallery). Two problems with the original
/// `.spectrum` face drive all of them:
/// - **It showed the wrong colors.** Its `AngularGradient` starts at 3 o'clock while the puck
///   puts hue 0 at 12 o'clock, and it spaces hues evenly while the engine's wheel hues aren't —
///   so the color under the puck was ~90° away from the tint actually applied. Every new face is
///   painted from `ColorBalanceWheelTint`, i.e. the engine's own math.
/// - **Too much color, unevenly bright.** A full HSB disc is the loudest thing in the bar, and at
///   one HSB saturation/brightness yellow still reads far lighter than blue. The new faces draw
///   hue at one *perceptual* lightness (OKLCH, `WheelPalette`), and most keep it to a thin ring
///   or to the one color actually chosen.
enum ColorWheelStyle: String, CaseIterable, Identifiable {
    case spectrum
    case ring
    case ringGlow
    case mutedDisc
    case graticule
    case ringReadout

    var id: Self { self }

    var label: String {
        switch self {
        case .spectrum: "Current · Spectrum Disc"
        case .ring: "A · Hue Ring"
        case .ringGlow: "B · Ring + Tint Glow"
        case .mutedDisc: "C · Muted Disc"
        case .graticule: "D · Scope Graticule"
        case .ringReadout: "E · Ring + Scrub Readout"
        }
    }
}

// MARK: - Palette

/// Wheel colors computed from what the engine really does (`ColorBalanceWheelTint`), re-expressed
/// at a fixed OKLCH lightness/chroma so every hue reads equally bright. Built once.
enum WheelPalette {
    /// OKLab hue angle (radians) of the real tint at each whole wheel degree, 0...359.
    private static let tintAngles: [Double] = (0..<360).map { degree in
        let lab = oklab(fromLinear: ColorBalanceWheelTint.linearRGB(hueDegrees: Double(degree)))
        return atan2(lab.z, lab.y)
    }

    static func tintAngle(forWheelHue hue: Double) -> Double {
        let index = (Int(hue.rounded()) % 360 + 360) % 360
        return tintAngles[index]
    }

    /// The real tint for `hue`, drawn at `lightness`/`chroma` (OKLCH), reduced in chroma as needed
    /// to stay inside sRGB.
    static func color(forWheelHue hue: Double, lightness: Double = 0.74, chroma: Double = 0.13) -> Color {
        color(angle: tintAngle(forWheelHue: hue), lightness: lightness, chroma: chroma)
    }

    /// Ring/disc gradient, starting at 12 o'clock and running clockwise — the same convention as
    /// `ColorWheelControl`'s puck (hue 0 at the top), so pair it with `startAngle: .degrees(-90)`.
    static func gradient(lightness: Double = 0.74, chroma: Double = 0.13) -> Gradient {
        Gradient(stops: stride(from: 0, through: 360, by: 10).map { degree in
            Gradient.Stop(color: color(forWheelHue: Double(degree % 360), lightness: lightness, chroma: chroma), location: Double(degree) / 360)
        })
    }

    static let ringGradient = gradient()
    static let mutedGradient = gradient(lightness: 0.46, chroma: 0.05)

    /// Plain-language name for `hue`'s real tint — what a readout shows instead of a bare angle.
    static func name(forWheelHue hue: Double) -> String {
        let degrees = (tintAngle(forWheelHue: hue) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let names: [(Double, String)] = [
            (8, "Pink"), (30, "Red"), (58, "Orange"), (100, "Yellow"), (140, "Green"),
            (190, "Teal"), (235, "Cyan"), (265, "Blue"), (300, "Violet"), (335, "Magenta"),
        ]
        func distance(_ a: Double, _ b: Double) -> Double { min(abs(a - b), 360 - abs(a - b)) }
        return names.min { distance($0.0, degrees) < distance($1.0, degrees) }!.1
    }

    /// The wheel hue whose real tint is closest to OKLab hue `degrees` — for placing named marks.
    static func wheelHue(nearestTintDegrees degrees: Double) -> Double {
        let target = degrees * .pi / 180
        func distance(_ a: Double) -> Double { abs(atan2(sin(a - target), cos(a - target))) }
        return Double((0..<360).min { distance(tintAngles[$0]) < distance(tintAngles[$1]) }!)
    }

    // MARK: Color Zones hue axis

    /// Color Zones' x-axis is CIELab hue (`ColorZonesKernel`: `atan2(b, a)` / 2π, D65 white) —
    /// not HSB hue, so yellow sits at 0.25 and blue near 0.8. This paints each x with the real
    /// Lab hue at that position, at the same OKLCH lightness/chroma as the wheel ring.
    static func colorZonesGradient(lightness: Double = 0.74, chroma: Double = 0.13) -> Gradient {
        Gradient(stops: stride(from: 0, through: 72, by: 1).map { step in
            let x = Double(step) / 72
            return Gradient.Stop(color: color(angle: okAngle(forLabHue: x * 2 * .pi), lightness: lightness, chroma: chroma), location: x)
        })
    }

    static let colorZonesAxis = colorZonesGradient()

    private static func okAngle(forLabHue hue: Double) -> Double {
        // A mid-lightness, moderate-chroma Lab color at this hue → XYZ (D65) → linear sRGB → OKLab.
        let L = 60.0, C = 30.0
        let a = C * cos(hue), b = C * sin(hue)
        func fInverse(_ t: Double) -> Double {
            let d = 6.0 / 29.0
            return t > d ? t * t * t : 3 * d * d * (t - 4.0 / 29.0)
        }
        let fy = (L + 16) / 116
        let x = 0.95047 * fInverse(fy + a / 500), y = fInverse(fy), z = 1.08883 * fInverse(fy - b / 200)
        let rgb = SIMD3(
            3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
            -0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
            0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        )
        let lab = oklab(fromLinear: SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0)))
        return atan2(lab.z, lab.y)
    }

    // MARK: OKLab (Björn Ottosson's reference matrices, linear sRGB)

    private static func oklab(fromLinear rgb: SIMD3<Double>) -> SIMD3<Double> {
        let l = cbrt(0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z)
        let m = cbrt(0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z)
        let s = cbrt(0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z)
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    private static func linear(fromOKLab lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3)
        let m = pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3)
        let s = pow(lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z, 3)
        return SIMD3(
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    /// Any OKLCH color (hue in degrees), gamut-clamped the same way — for controls outside the
    /// wheels that should sit at the same perceptual lightness (e.g. `WhiteBalanceStyles`).
    static func oklch(hueDegrees: Double, lightness: Double = 0.74, chroma: Double = 0.13) -> Color {
        color(angle: hueDegrees * .pi / 180, lightness: lightness, chroma: chroma)
    }

    private static func color(angle: Double, lightness: Double, chroma: Double) -> Color {
        var c = chroma
        var rgb = linear(fromOKLab: SIMD3(lightness, c * cos(angle), c * sin(angle)))
        while (rgb.min() < 0 || rgb.max() > 1) && c > 0.005 {
            c -= 0.005
            rgb = linear(fromOKLab: SIMD3(lightness, c * cos(angle), c * sin(angle)))
        }
        func encode(_ v: Double) -> Double {
            let v = min(max(v, 0), 1)
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return Color(.sRGB, red: encode(rgb.x), green: encode(rgb.y), blue: encode(rgb.z))
    }
}

// MARK: - Faces

/// The inside of the wheel for every style except `.spectrum` (which `ColorWheelControl` still
/// draws itself). Purely visual — the puck drag, double-click reset, and luminance arc all stay in
/// `ColorWheelControl`, so every style edits exactly the same way.
struct ColorWheelFace: View {
    let style: ColorWheelStyle
    let diameter: CGFloat
    let hue: Double
    /// 0...1 — chroma as a fraction of the wheel's calibrated edge.
    let radiusFraction: CGFloat
    let puckOffset: CGSize
    let puckDiameter: CGFloat

    @Environment(ColorSchemeStore.self) private var uiColors

    private var radius: CGFloat { diameter / 2 }
    private var isNeutral: Bool { radiusFraction < 0.02 }
    private var tint: Color { WheelPalette.color(forWheelHue: hue) }

    var body: some View {
        ZStack {
            Circle().fill(uiColors.recessedTrackBackground)

            switch style {
            case .spectrum:
                EmptyView()
            case .ring, .ringReadout:
                crosshair
                ring(width: 4)
            case .ringGlow:
                glow
                crosshair
                ring(width: 6)
            case .mutedDisc:
                Circle()
                    .fill(AngularGradient(gradient: WheelPalette.mutedGradient, center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)))
                    // Fades to the recessed background at the center (neutral = no color), rather
                    // than the old face's white center, which was the brightest spot in the bar.
                    .overlay(Circle().fill(RadialGradient(
                        colors: [uiColors.recessedTrackBackground, uiColors.recessedTrackBackground.opacity(0)],
                        center: .center, startRadius: 0, endRadius: radius
                    )))
                Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            case .graticule:
                graticule
            }

            if !isNeutral { spoke }
            Circle()
                .fill(Color.primary.opacity(0.4))
                .frame(width: 3, height: 3)
            puck
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    private func ring(width: CGFloat) -> some View {
        Circle().strokeBorder(
            AngularGradient(gradient: WheelPalette.ringGradient, center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
            lineWidth: width
        )
    }

    private var crosshair: some View {
        Path { path in
            path.move(to: CGPoint(x: radius, y: 8)); path.addLine(to: CGPoint(x: radius, y: diameter - 8))
            path.move(to: CGPoint(x: 8, y: radius)); path.addLine(to: CGPoint(x: diameter - 8, y: radius))
        }
        .stroke(Color.white.opacity(0.06), lineWidth: 1)
    }

    /// Only the chosen color, washing in from the puck's side as chroma grows — the wheel shows
    /// what it's doing to the photo, not every color it could do.
    private var glow: some View {
        Circle().fill(RadialGradient(
            colors: [tint.opacity(0.45 * Double(radiusFraction)), tint.opacity(0)],
            center: UnitPoint(x: 0.5 + puckOffset.width / diameter, y: 0.5 + puckOffset.height / diameter),
            startRadius: 0, endRadius: diameter * 0.75
        ))
    }

    /// Vectorscope-style: hairline chroma rings at thirds, and six named hue targets placed where
    /// the engine's real red/yellow/green/cyan/blue/magenta land on *this* wheel.
    private var graticule: some View {
        ZStack {
            ForEach([1.0 / 3, 2.0 / 3, 1.0], id: \.self) { fraction in
                Circle()
                    .stroke(Color.white.opacity(fraction == 1 ? 0.14 : 0.07), lineWidth: 1)
                    .frame(width: diameter * fraction, height: diameter * fraction)
            }
            ForEach(Self.targets, id: \.letter) { target in
                let angle = (90 - target.wheelHue) * .pi / 180
                Circle()
                    .fill(WheelPalette.color(forWheelHue: target.wheelHue))
                    .frame(width: 5, height: 5)
                    .offset(x: radius * 0.86 * cos(angle), y: -radius * 0.86 * sin(angle))
                Text(target.letter)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .offset(x: radius * 0.66 * cos(angle), y: -radius * 0.66 * sin(angle))
            }
        }
    }

    private static let targets: [(letter: String, wheelHue: Double)] = [
        ("R", 29), ("Y", 110), ("G", 142), ("C", 195), ("B", 264), ("M", 328),
    ].map { ($0.0, WheelPalette.wheelHue(nearestTintDegrees: $0.1)) }

    private var spoke: some View {
        Path { path in
            path.move(to: CGPoint(x: radius, y: radius))
            path.addLine(to: CGPoint(x: radius + puckOffset.width, y: radius + puckOffset.height))
        }
        .stroke(tint.opacity(0.7), lineWidth: style == .ringGlow ? 1 : 1.5)
    }

    /// Ring + Tint Glow gets a smaller, lighter puck — the glow already says where the color is,
    /// so the puck only needs to mark the exact point.
    private var puck: some View {
        let isCompact = style == .ringGlow
        let size = isCompact ? 7 : puckDiameter
        return Circle()
            .fill(isNeutral ? Color(white: 0.75) : tint)
            .overlay(Circle().stroke(Color.white, lineWidth: isCompact ? 1 : 1.5))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.5), radius: isCompact ? 1 : 1.5)
            .offset(puckOffset)
    }
}

// MARK: - Readout

/// Style E's row under the wheel: the tint by name, and its strength — each drag-scrubbable
/// horizontally (⇧ = fine), for precise values the puck can't give at this size.
struct ColorWheelReadout: View {
    @Binding var hue: Double
    @Binding var chroma: Double
    let maxChroma: Double
    var onChange: () -> Void

    @State private var dragStart: (hue: Double, chroma: Double)?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(chroma == 0 ? Color(white: 0.5) : WheelPalette.color(forWheelHue: hue))
                    .frame(width: 6, height: 6)
                Text(chroma == 0 ? "Neutral" : WheelPalette.name(forWheelHue: hue))
            }
            .gesture(scrub { start, dx in
                hue = (start.hue + dx).truncatingRemainder(dividingBy: 360)
                if hue < 0 { hue += 360 }
            })
            Text("\(Int((chroma / maxChroma * 100).rounded()))%")
                .monospacedDigit()
                .gesture(scrub { start, dx in
                    chroma = min(max(start.chroma + dx / 150 * maxChroma, 0), maxChroma)
                })
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
    }

    private func scrub(_ apply: @escaping ((hue: Double, chroma: Double), Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let start = dragStart ?? (hue, chroma)
                dragStart = start
                let factor = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1
                apply(start, Double(drag.translation.width) * factor)
                onChange()
            }
            .onEnded { _ in dragStart = nil }
    }
}
