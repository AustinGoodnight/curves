import SwiftUI
import RawEngine

/// The top of the editor's right sidebar: four ways to read the rendered photo's data, one at a
/// time behind small tabs (the last-used tab is remembered). Kept to a single panel rather than
/// stacking scopes — per this app's "visualize only what isn't obvious" rule, each tab answers a
/// different question:
/// - **Histogram** — how many pixels at each brightness, per channel.
/// - **Waveform** — brightness by *position* across the frame: where highlights clip or shadows
///   crush, and (RGB overlay) where a color cast lives.
/// - **Vectorscope** — which colors, how saturated: hue by angle, saturation by distance from the
///   neutral center, with primary/secondary targets and the skin-tone line.
/// - **Zones** — Ansel Adams' zone system: share of the photo in each one-stop zone around middle
///   grey (Zone V), for judging exposure placement in photographer's terms.
///
/// Its own `View`, reading `coordinator`'s data inside its own `body`, so a new render only
/// re-renders this panel — not the sidebar's controls below it.
struct PhotoDataPanel: View {
    let coordinator: EditorRenderCoordinator
    var height: CGFloat = 240

    enum Scope: String, CaseIterable, Identifiable {
        case histogram = "Histogram"
        case waveform = "Waveform"
        case vectorscope = "Vectorscope"
        case zones = "Zones"
        var id: Self { self }
    }

    @AppStorage("photoDataScope") private var scope: Scope = .histogram
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            scopeSelector
            Group {
                switch scope {
                case .histogram:
                    RGBHistogramView(data: coordinator.rgbHistogram, height: height, stats: coordinator.toneStats)
                case .waveform:
                    WaveformScope(image: coordinator.waveformImage, height: height)
                case .vectorscope:
                    VectorscopeView(image: coordinator.vectorscopeImage, height: height)
                case .zones:
                    ZoneSystemView(histogram: coordinator.luminanceHistogram, height: height)
                }
            }
            .frame(maxWidth: .infinity)
            // Click anywhere on the visualization to cycle to the next one (wrapping) — quicker
            // than aiming for a dot when flipping through views.
            .contentShape(Rectangle())
            .onTapGesture {
                let all = Scope.allCases
                let next = all[((all.firstIndex(of: scope) ?? 0) + 1) % all.count]
                withAnimation(.easeOut(duration: 0.15)) { scope = next }
            }
            .help("Click to switch to the next view")
        }
    }
}

extension PhotoDataPanel {
    /// One lit dot + label per view, spread across the panel's width — the same "which one is on"
    /// dot language as `StoplightToggle` (accent + soft glow when lit, grey when not), used here as
    /// a one-of-four radio group instead of the old pill tabs.
    fileprivate var scopeSelector: some View {
        HStack(spacing: 0) {
            ForEach(Scope.allCases) { item in
                let isSelected = scope == item
                HStack(spacing: 6) {
                    Circle()
                        .fill(isSelected ? uiColors.accentColor : Color(white: 0.4))
                        .frame(width: 8, height: 8)
                        .shadow(color: isSelected ? uiColors.accentColor.opacity(0.5) : .clear, radius: 2.5)
                    Text(item.rawValue)
                        .font(.scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .fixedSize()
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { scope = item }
                }
                .help(item.explanation)
            }
        }
    }
}

extension PhotoDataPanel.Scope {
    /// Tooltip — what question each view answers.
    var explanation: String {
        switch self {
        case .histogram: "How many pixels sit at each brightness, per color channel"
        case .waveform: "Brightness across the frame, left to right — shows where highlights clip"
        case .vectorscope: "Which colors, and how saturated — hue by angle, saturation by distance from center"
        case .zones: "Ansel Adams' zone system — share of the photo in each one-stop zone around middle grey (V)"
        }
    }
}

// MARK: - Waveform

private struct WaveformScope: View {
    let image: CGImage?
    let height: CGFloat
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(uiColors.recessedTrackBackground)
            GeometryReader { geo in
                let h = geo.size.height
                // IRE-style guides at 0/25/50/75/100%.
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    let y = h * (1 - level)
                    Rectangle()
                        .fill(Color.white.opacity(level == 0 || level == 1 ? 0.14 : 0.06))
                        .frame(height: 1)
                        .offset(y: min(max(y - 0.5, 0), h - 1))
                    Text("\(Int(level * 100))")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .offset(x: 4, y: min(max(y - 10, 1), h - 11))
                }
            }
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .blendMode(.plusLighter)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 1)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Vectorscope

private struct VectorscopeView: View {
    let image: CGImage?
    let height: CGFloat
    @Environment(ColorSchemeStore.self) private var uiColors

    private static let targets = PhotoScopes.vectorscopeTargets()
    private static let skinAngle = PhotoScopes.skinToneAngle()

    var body: some View {
        let diameter = height
        let radius = diameter / 2
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(uiColors.recessedTrackBackground)
            ZStack {
                Circle().fill(Color.black.opacity(0.35))
                // Saturation rings at 25/50/75/100% and the two neutral axes.
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                    Circle()
                        .strokeBorder(Color.white.opacity(fraction == 1 ? 0.18 : 0.06), lineWidth: 1)
                        .frame(width: diameter * fraction, height: diameter * fraction)
                }
                Path { p in
                    p.move(to: CGPoint(x: radius, y: 0)); p.addLine(to: CGPoint(x: radius, y: diameter))
                    p.move(to: CGPoint(x: 0, y: radius)); p.addLine(to: CGPoint(x: diameter, y: radius))
                }
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                // Skin-tone line, center to rim.
                Path { p in
                    p.move(to: CGPoint(x: radius, y: radius))
                    p.addLine(to: point(angle: Self.skinAngle, fraction: 1, radius: radius))
                }
                .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .blendMode(.plusLighter)
                        .clipShape(Circle())
                }
                // Primary/secondary targets.
                ForEach(Self.targets.indices, id: \.self) { index in
                    let target = Self.targets[index]
                    let center = point(angle: target.angle, fraction: target.radius, radius: radius)
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                        .frame(width: 9, height: 9)
                        .position(center)
                    Text(target.label)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .position(point(angle: target.angle, fraction: min(target.radius + 0.1, 0.97), radius: radius))
                }
                Text("skin")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .position(point(angle: Self.skinAngle, fraction: 1.08, radius: radius))
            }
            .frame(width: diameter, height: diameter)
        }
        .frame(height: height + 16)
    }

    /// Plot coordinates: +a* to the right, +b* up (screen y flipped), `fraction` of the radius out.
    private func point(angle: Double, fraction: Double, radius: CGFloat) -> CGPoint {
        CGPoint(
            x: radius + CGFloat(cos(angle) * fraction) * radius,
            y: radius - CGFloat(sin(angle) * fraction) * radius
        )
    }
}

// MARK: - Zones

private struct ZoneSystemView: View {
    let histogram: [Float]
    let height: CGFloat
    @Environment(ColorSchemeStore.self) private var uiColors

    private static let numerals = ["0", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]

    /// Share of pixels per zone. Each histogram bin (display-referred) is linearized (2.2) and
    /// placed by stops from 18% grey: Zone V = middle grey, one zone per stop, clamped to 0…X.
    private var zoneFractions: [Double] {
        var zones = [Double](repeating: 0, count: 11)
        let total = histogram.reduce(0, +)
        guard histogram.count > 1, total > 0 else { return zones }
        for (i, count) in histogram.enumerated() {
            let display = (Double(i) + 0.5) / Double(histogram.count)
            let linear = pow(display, 2.2)
            let stops = log2(max(linear, 1e-6) / 0.18)
            let zone = min(max(Int((5 + stops).rounded()), 0), 10)
            zones[zone] += Double(count) / Double(total)
        }
        return zones
    }

    /// What each zone looks like, for its swatch: 18% grey scaled by its stop offset, re-encoded.
    private func zoneGrey(_ zone: Int) -> Color {
        Color(white: min(pow(0.18 * pow(2, Double(zone - 5)), 1 / 2.2), 1))
    }

    var body: some View {
        let fractions = zoneFractions
        let peak = max(fractions.max() ?? 0, 0.001)
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(uiColors.recessedTrackBackground)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<11, id: \.self) { zone in
                    VStack(spacing: 4) {
                        Text(fractions[zone] >= 0.005 ? "\(Int((fractions[zone] * 100).rounded()))%" : "")
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        GeometryReader { geo in
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(zone == 5 ? 0.55 : 0.3))
                                    .frame(height: max(fractions[zone] > 0 ? 2 : 0, geo.size.height * fractions[zone] / peak))
                            }
                        }
                        RoundedRectangle(cornerRadius: 2)
                            .fill(zoneGrey(zone))
                            .frame(height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                        Text(Self.numerals[zone])
                            .font(.system(size: 8, weight: zone == 5 ? .bold : .regular))
                            .foregroundStyle(zone == 5 ? Color.primary : Color.secondary)
                    }
                }
            }
            .padding(10)
        }
        .frame(height: height)
        .help("Zone V is middle grey; each zone is one stop brighter or darker")
    }
}
