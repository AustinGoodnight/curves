import SwiftUI
import RawEngine

/// Overlaid red/green/blue channel histograms, screen-blended so overlapping channels read as
/// yellow/cyan/magenta/white — the standard photo-app RGB histogram look, distinct from the
/// single luminance histogram already backing `CurveEditorControl`'s RGB Curve graph. Channel
/// colors match `Gradient.colorIntensity`'s red/green/blue stops, for the same vivid-but-not-
/// harsh look used everywhere else color gets drawn literally as color in this editor.
///
/// When shown in `PhotoDataPanel` it also carries the same kind of reference marks as the other
/// scopes there: quarter-tone guides with 0/25/50/75/100 labels (matching the waveform's scale),
/// and — given `stats` — clipping warnings at each end: a blue (crushed shadows) or red (blown
/// highlights) edge bar sized by how much is clipped, plus the percentage.
struct RGBHistogramView: View {
    let data: RGBHistogramData
    var height: CGFloat = 90
    /// Clip fractions for the edge warnings; `nil` hides them.
    var stats: ImageToneStats? = nil
    @Environment(ColorSchemeStore.self) private var uiColors

    private static let shadowClipColor = Color(red: 0.36, green: 0.56, blue: 1.0)
    private static let highlightClipColor = Color(red: 1.0, green: 0.36, blue: 0.3)

    private static let redColor = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)
    private static let greenColor = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    private static let blueColor = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(uiColors.recessedTrackBackground)
            GeometryReader { geo in
                let w = geo.size.width
                // Quarter-tone guides behind the channels.
                ForEach([0.25, 0.5, 0.75], id: \.self) { level in
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 1)
                        .offset(x: w * level - 0.5)
                }
            }
            Canvas { context, size in
                context.blendMode = .screen
                fill(data.r, color: Self.redColor, in: &context, size: size)
                fill(data.g, color: Self.greenColor, in: &context, size: size)
                fill(data.b, color: Self.blueColor, in: &context, size: size)
            }
            if let stats {
                clipWarnings(stats)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    Text("\(Int(level * 100))")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .fixedSize()
                        .position(x: min(max(w * level, 9), w - 9), y: geo.size.height - 7)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Edge bars (height ∝ how much is clipped, perceptual scale) and percentage badges — only
    /// when a meaningful share of the photo (≥ 0.05%) is actually clipped at that end.
    @ViewBuilder
    private func clipWarnings(_ stats: ImageToneStats) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                if stats.shadowClipFraction >= 0.0005 {
                    Rectangle()
                        .fill(Self.shadowClipColor)
                        .frame(width: 3, height: h * Self.intensity(stats.shadowClipFraction))
                        .offset(y: h * (1 - Self.intensity(stats.shadowClipFraction)))
                    badge("◀ " + Self.percent(stats.shadowClipFraction), color: Self.shadowClipColor)
                        .offset(x: 7, y: 5)
                }
                if stats.highlightClipFraction >= 0.0005 {
                    Rectangle()
                        .fill(Self.highlightClipColor)
                        .frame(width: 3, height: h * Self.intensity(stats.highlightClipFraction))
                        .offset(x: geo.size.width - 3, y: h * (1 - Self.intensity(stats.highlightClipFraction)))
                    badge(Self.percent(stats.highlightClipFraction) + " ▶", color: Self.highlightClipColor)
                        .frame(width: geo.size.width - 7, alignment: .trailing)
                        .offset(y: 5)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .fixedSize()
    }

    private static func intensity(_ fraction: Float) -> CGFloat {
        CGFloat(min(1, Double(fraction * 20).squareRoot()))
    }

    private static func percent(_ fraction: Float) -> String {
        fraction < 0.01 ? String(format: "%.1f%%", fraction * 100) : String(format: "%.0f%%", fraction * 100)
    }

    /// A filled area chart (not individual bars) — with three channels overlapping via
    /// `.screen`, discrete bar edges just add visual noise; a smooth outline through each bin's
    /// center (not a stair-step per bin) reads more clearly.
    private func fill(_ bins: [Float], color: Color, in context: inout GraphicsContext, size: CGSize) {
        guard bins.count > 1 else { return }
        let binWidth = size.width / CGFloat(bins.count)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height - CGFloat(bins[0]) * size.height))
        for (i, value) in bins.enumerated() {
            let x = (CGFloat(i) + 0.5) * binWidth
            let y = size.height - CGFloat(value) * size.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height - CGFloat(bins[bins.count - 1]) * size.height))
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(color.opacity(0.8)))
    }
}
