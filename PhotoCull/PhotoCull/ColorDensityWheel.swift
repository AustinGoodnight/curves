import SwiftUI
import RawEngine

/// A circular "where do this image's colors actually live" density plot — hue around the ring,
/// chroma (color intensity) from center outward, each cell lit up in its own true hue at an
/// opacity proportional to how many sampled pixels fall there. Empty cells stay near-black, so
/// the shape that lights up is this image's own color fingerprint, unlike `ColorWheelControl`'s
/// fixed reference wheel (which shows every hue at full brightness regardless of the photo).
struct ColorDensityWheel: View {
    /// `hueBins * chromaBins` counts, row-major (`hueBin * chromaBins + chromaBin`) — see
    /// `Histogram.colorDensity(from:)`, which this must stay in sync with.
    let density: [Float]
    var hueBins: Int = 48
    var chromaBins: Int = 12
    var diameter: CGFloat = 160

    var body: some View {
        Canvas { context, size in
            guard density.count == hueBins * chromaBins else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxRadius = min(size.width, size.height) / 2
            for h in 0..<hueBins {
                for c in 0..<chromaBins {
                    let value = density[h * chromaBins + c]
                    let hueFraction = (Double(h) + 0.5) / Double(hueBins)
                    let color = Color(hue: hueFraction, saturation: 0.9, brightness: 1)
                    let opacity = 0.05 + 0.95 * Double(value)
                    context.fill(wedge(hueBin: h, chromaBin: c, center: center, maxRadius: maxRadius), with: .color(color.opacity(opacity)))
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(Color.black.opacity(0.35)))
        .clipShape(Circle())
    }

    /// Built from plotted points (`cos`/`sin` at each corner), the same technique
    /// `ColorWheelControl`'s `arcPath`/`arcHitPath` use for their own arcs — sidesteps
    /// `Path.addArc`'s clockwise/coordinate-system ambiguity, which produced a mismatched track
    /// in an earlier pass at that control.
    private func wedge(hueBin: Int, chromaBin: Int, center: CGPoint, maxRadius: CGFloat) -> Path {
        let innerRadius = maxRadius * CGFloat(chromaBin) / CGFloat(chromaBins)
        let outerRadius = maxRadius * CGFloat(chromaBin + 1) / CGFloat(chromaBins)
        let startAngle = Double(hueBin) / Double(hueBins) * 360
        let endAngle = Double(hueBin + 1) / Double(hueBins) * 360
        let steps = 3

        func point(_ angleDegrees: Double, _ radius: CGFloat) -> CGPoint {
            let radians = angleDegrees * .pi / 180
            return CGPoint(x: center.x + radius * CGFloat(cos(radians)), y: center.y + radius * CGFloat(sin(radians)))
        }

        var path = Path()
        path.move(to: point(startAngle, outerRadius))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            path.addLine(to: point(startAngle + (endAngle - startAngle) * t, outerRadius))
        }
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            path.addLine(to: point(endAngle - (endAngle - startAngle) * t, innerRadius))
        }
        path.closeSubpath()
        return path
    }
}
