import SwiftUI

/// Candidate visualizations for the Off/Filmic/AgX tone-mapper choice — shown all at once in
/// `EditorSidebarView`'s "Tone Mapper Styles" comparison panel so one can be picked, the same way
/// the "Slider Styles" comparison row settled `MinimalSlider`'s track/thumb. Every style is fully
/// live (bound to the same selection), so they can be compared by actually using them. Once one
/// wins, the rest (and the comparison panel) should be deleted.

// MARK: - Shared

extension ToneMapper {
    static let allCases: [ToneMapper] = [.off, .filmic, .agx]

    var label: String {
        switch self {
        case .off: "Off"
        case .filmic: "Filmic"
        case .agx: "AgX"
        }
    }

    /// A rough, illustrative transfer curve for previews only — scene value (0…1, spanning a
    /// few stops past display white) in, display value out. Not the real Filmic/AgX math, just
    /// the characteristic shape of each: Off clips hard at display white, Filmic is a punchy S
    /// with a soft shoulder, AgX a gentler, lower-contrast S that rolls off even more gradually.
    func previewCurve(_ x: Double) -> Double {
        switch self {
        case .off:
            return min(x * 1.6, 1)
        case .filmic:
            return logisticNormalized(x, slope: 9, midpoint: 0.42)
        case .agx:
            return logisticNormalized(x, slope: 6, midpoint: 0.45) * 0.97 + 0.02
        }
    }

    private func logisticNormalized(_ x: Double, slope: Double, midpoint: Double) -> Double {
        func f(_ t: Double) -> Double { 1 / (1 + exp(-slope * (t - midpoint))) }
        return (f(x) - f(0)) / (f(1) - f(0))
    }
}

/// `mapper`'s preview curve as a stroked path filling its frame, origin bottom-left.
private struct ToneCurveShape: Shape {
    let mapper: ToneMapper

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 40
        for i in 0...steps {
            let x = Double(i) / Double(steps)
            let point = CGPoint(
                x: rect.minX + rect.width * x,
                y: rect.maxY - rect.height * mapper.previewCurve(x)
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// A black → past-white ramp pushed through `mapper`'s preview curve — shows at a glance where
/// highlights clip (Off: a flat white band) versus roll off smoothly (Filmic/AgX).
private func rolloffGradient(_ mapper: ToneMapper) -> LinearGradient {
    let stops = (0...16).map { i -> Gradient.Stop in
        let x = Double(i) / 16
        return .init(color: Color(white: mapper.previewCurve(x)), location: x)
    }
    return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
}

// MARK: - 1. Sliding Pill

/// A custom segmented control — recessed capsule track with a lighter capsule that slides to the
/// selected option, instead of the native segmented `Picker`'s system chrome.
struct ToneMapperSlidingPill: View {
    @Binding var selection: ToneMapper
    @Environment(ColorSchemeStore.self) private var uiColors
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ToneMapper.allCases, id: \.self) { mapper in
                Text(mapper.label)
                    .font(.caption.weight(selection == mapper ? .semibold : .regular))
                    .foregroundStyle(selection == mapper ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if selection == mapper {
                            Capsule()
                                .fill(Color.white.opacity(0.14))
                                .matchedGeometryEffect(id: "pill", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.25)) { selection = mapper }
                    }
            }
        }
        .padding(3)
        .background(uiColors.recessedTrackBackground, in: Capsule())
    }
}

// MARK: - 2. Curve Tiles

/// Three tiles, each drawing its mapper's characteristic tone curve — the choice is shown as
/// *what it does to the image's tones*, not just a name.
struct ToneMapperCurveTiles: View {
    @Binding var selection: ToneMapper
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ToneMapper.allCases, id: \.self) { mapper in
                let isSelected = selection == mapper
                VStack(spacing: 6) {
                    ZStack {
                        // Faint diagonal "identity" reference line.
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: 1))
                            p.addLine(to: CGPoint(x: 1, y: 0))
                        }
                        .applying(CGAffineTransform(scaleX: 60, y: 36))
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        ToneCurveShape(mapper: mapper)
                            .stroke(
                                isSelected ? uiColors.accentColor : Color.white.opacity(0.4),
                                style: StrokeStyle(lineWidth: isSelected ? 2 : 1.5, lineCap: .round)
                            )
                    }
                    .frame(width: 60, height: 36)
                    Text(mapper.label)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? uiColors.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { selection = mapper }
            }
        }
    }
}

// MARK: - 3. Rolloff Strips

/// One row per mapper — name plus a black-to-past-white ramp run through that mapper, so the
/// difference in highlight handling (hard clip vs. soft shoulder) is visible directly.
struct ToneMapperRolloffStrips: View {
    @Binding var selection: ToneMapper
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ToneMapper.allCases, id: \.self) { mapper in
                let isSelected = selection == mapper
                HStack(spacing: 10) {
                    Circle()
                        .fill(isSelected ? uiColors.accentColor : Color.white.opacity(0.15))
                        .frame(width: 7, height: 7)
                    Text(mapper.label)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(width: 40, alignment: .leading)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(rolloffGradient(mapper))
                        .frame(height: 12)
                        .opacity(isSelected ? 1 : 0.55)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    isSelected ? Color.white.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
                .onTapGesture { selection = mapper }
            }
        }
        .padding(4)
        .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 4. Underline Tabs

/// Plain text labels with an accent underline that slides under the selected one — the lightest-
/// weight option, closest to how Color Zones' channel switcher reads.
struct ToneMapperUnderlineTabs: View {
    @Binding var selection: ToneMapper
    @Environment(ColorSchemeStore.self) private var uiColors
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ToneMapper.allCases, id: \.self) { mapper in
                let isSelected = selection == mapper
                VStack(spacing: 5) {
                    Text(mapper.label)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    ZStack {
                        Capsule().fill(Color.white.opacity(0.08)).frame(height: 2)
                        if isSelected {
                            Capsule()
                                .fill(uiColors.accentColor)
                                .frame(height: 2)
                                .matchedGeometryEffect(id: "underline", in: namespace)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.25)) { selection = mapper }
                }
            }
        }
    }
}

// MARK: - 5. Stoplight Dots

/// Three labeled dots, only the selected one lit — the same "is this on" dot language as
/// `StoplightToggle` everywhere else, turned into a one-of-three radio group.
struct ToneMapperStoplightDots: View {
    @Binding var selection: ToneMapper
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ToneMapper.allCases, id: \.self) { mapper in
                let isSelected = selection == mapper
                HStack(spacing: 6) {
                    Circle()
                        .fill(isSelected ? uiColors.accentColor : Color.white.opacity(0.12))
                        .overlay(Circle().strokeBorder(Color.white.opacity(isSelected ? 0 : 0.2), lineWidth: 1))
                        .frame(width: 10, height: 10)
                        .shadow(color: isSelected ? uiColors.accentColor.opacity(0.5) : .clear, radius: 3)
                    Text(mapper.label)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { selection = mapper }
            }
        }
        .padding(.horizontal, 4)
        .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 6. Curve Carousel

/// One large curve preview with ‹ › arrows to step through the three — the selected mapper's
/// curve gets the whole row, with the other two drawn faintly behind it for comparison.
struct ToneMapperCurveCarousel: View {
    @Binding var selection: ToneMapper
    /// `false` when the caller already supplies the recessed box (the editor sidebar's tone-mapper
    /// row, which also holds the settings chevron) — avoids a box drawn inside a box.
    var drawsBackground = true
    @Environment(ColorSchemeStore.self) private var uiColors

    private func step(_ delta: Int) {
        let all = ToneMapper.allCases
        guard let index = all.firstIndex(of: selection) else { return }
        withAnimation(.snappy(duration: 0.25)) {
            selection = all[(index + delta + all.count) % all.count]
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            arrow("chevron.left") { step(-1) }
            VStack(spacing: 4) {
                ZStack {
                    ForEach(ToneMapper.allCases.filter { $0 != selection }, id: \.self) { mapper in
                        ToneCurveShape(mapper: mapper)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    ToneCurveShape(mapper: selection)
                        .stroke(uiColors.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                .frame(height: 40)
                Text(selection.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            arrow("chevron.right") { step(1) }
        }
        .padding(drawsBackground ? 8 : 0)
        .background(drawsBackground ? uiColors.recessedTrackBackground : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func arrow(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
