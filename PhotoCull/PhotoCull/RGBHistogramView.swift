import SwiftUI
import RawEngine

/// Overlaid red/green/blue channel histograms, screen-blended so overlapping channels read as
/// yellow/cyan/magenta/white — the standard photo-app RGB histogram look, distinct from the
/// single luminance histogram already backing `CurveEditorControl`'s RGB Curve graph. Channel
/// colors match `Gradient.colorIntensity`'s red/green/blue stops, for the same vivid-but-not-
/// harsh look used everywhere else color gets drawn literally as color in this editor.
struct RGBHistogramView: View {
    let data: RGBHistogramData
    var height: CGFloat = 90

    private static let redColor = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)
    private static let greenColor = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    private static let blueColor = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)

    var body: some View {
        Canvas { context, size in
            context.blendMode = .screen
            fill(data.r, color: Self.redColor, in: &context, size: size)
            fill(data.g, color: Self.greenColor, in: &context, size: size)
            fill(data.b, color: Self.blueColor, in: &context, size: size)
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.2), lineWidth: 1))
    }

    /// A filled area chart (not individual bars) — with three channels overlapping via
    /// `.screen`, discrete bar edges just add visual noise; a smooth outline reads more clearly.
    private func fill(_ bins: [Float], color: Color, in context: inout GraphicsContext, size: CGSize) {
        guard !bins.isEmpty else { return }
        let binWidth = size.width / CGFloat(bins.count)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, value) in bins.enumerated() {
            let x = CGFloat(i) * binWidth
            let y = size.height - CGFloat(value) * size.height
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + binWidth, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(color.opacity(0.8)))
    }
}
