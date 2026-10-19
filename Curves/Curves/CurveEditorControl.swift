import SwiftUI
import RawEngine

/// A Lightroom/Photoshop-style tone curve editor: drag existing points, click empty graph space
/// to add a new one (up to `RGBCurveKernel.maxNodes`), double-click an interior point to remove
/// it. The two endpoints are always present and can't be removed. Interior points drag freely in
/// both axes; when `showEndpointControls` is on, the two endpoints instead each lock one axis for
/// the duration of a drag: the bottom (black point) endpoint locks x and slides in y along the
/// left edge (its input stays fixed; only its output level changes), while the top (white point)
/// endpoint locks y and slides in x along the top edge instead — see `handleEndpointDrag`'s doc
/// comment for why, and for why the two endpoints don't even move at the same speed as each other.
/// When `showEndpointControls` is on, the two endpoint handles also render as triangles (pointing
/// into the graph from the edge each is pinned to) instead of the plain circle every interior
/// point uses, marking at a glance that these two only slide along their own edge.
///
/// `showEndpointControls` defaults off and only RGB Curve's own call site turns it on — Color
/// Zones' curve has no black/white-point concept (its endpoints aren't fixed at x=0/x=1 the way
/// RGB Curve's are; its reference is a flat line, not a diagonal), so it keeps the plain free-drag
/// behavior every other point already has.
///
/// Width is driven by whatever space the parent gives it (via `GeometryReader`) rather than a
/// fixed constant, so this stretches to fill a full-width bar; `height` is the one fixed
/// dimension, passed in by the caller.
struct CurveEditorControl: View {
    @Binding var points: [SIMD2<Double>]
    var title: String = "Curve"
    var height: CGFloat = 220
    /// The curve's true no-op shape (per whatever formula the *caller* applies it with) —
    /// RGB Curve's is `[(0,0), (1,1)]` (a diagonal), Color Zones' is `[(0.25,0.5), (0.75,0.5)]`
    /// (flat at 0.5). Used both to disable the reset button when already at default and as the
    /// reset target.
    var identityPoints: [SIMD2<Double>] = RGBCurveParameters.identityPoints
    /// Matches whichever kernel this curve feeds — `RGBCurveKernel.maxNodes` /
    /// `ColorZonesKernel.maxNodes` are both 8 today, but this keeps the widget from silently
    /// depending on that coincidence.
    var maxPoints: Int = RGBCurveKernel.maxNodes
    var splineType: RGBCurveSpline.SplineType = .monotoneHermite
    /// RGB Curve's reference is the y = x diagonal (identity mapping); Color Zones' is a flat
    /// line at y = 0.5 (no adjustment at any hue) — the two modules' curves mean different
    /// things, so the "no-op" guide line has a different shape.
    var referenceIsFlat = false
    /// Bin counts normalized to [0, 1] (see `Histogram`) drawn as a backdrop behind the curve —
    /// `nil`/empty draws nothing. `x` position of bin `i` is `i / histogram.count`, spanning the
    /// same [0, 1] domain as the curve itself, so a luminance or hue histogram lines up directly
    /// under the points that affect that range.
    var histogram: [Float]? = nil
    /// Color Zones' x-axis *is* hue (0...1 mapping to 0°...360° of Lab hue): draws a hue stripe
    /// along the no-op line plus a hue tint wherever the curve departs from it (see
    /// `hueTintFill`), so you can see which colors each x-position affects. RGB Curve's x-axis is
    /// input tone, not hue, so this stays off there.
    var showHueAxis: Bool = false
    /// Hides the title / "click to add a point" hint / per-curve reset row — for call sites that
    /// already show their own title and reset elsewhere (Color Zones folds its reset into the
    /// tab strip above the graph instead) and don't want the hint text competing with a busier
    /// surrounding layout.
    var showHeader: Bool = true
    /// Squares off the graph's top corners so it can sit flush beneath another rounded element
    /// (Color Zones' channel-switcher strip in `ColorBalanceBarView`) with no mismatched seam —
    /// the two read as one continuous card instead of two stacked, independently-rounded boxes.
    var topCornersSquared: Bool = false
    /// Curve stroke color — `.accentColor` (blue) reads fine against RGB Curve's plain grey
    /// background, but blends into the blue stretch of Color Zones' own hue-spectrum background,
    /// so that call site overrides it.
    var lineColor: Color = .accentColor
    /// See the struct doc comment — off by default, RGB Curve's call site turns it on, Color
    /// Zones leaves it off.
    var showEndpointControls: Bool = false
    /// Light quarter-division gridlines behind the curve — off by default (RGB Curve's histogram
    /// backdrop already gives it enough visual reference); Color Zones' call site turns it on
    /// since its curve sits over a plain hue-spectrum background with nothing else to judge
    /// position against.
    var showGrid: Bool = false
    /// How the hue axis is drawn when `showHueAxis` is on — see `HueGraphStyle`.
    var hueStyle: HueGraphStyle = .centerStripe
    /// What's behind the hue-axis graph — see `HueGraphBackground`. RGB Curve ignores it.
    var hueBackground: HueGraphBackground = .recessed
    var onChange: () -> Void = {}

    /// Minimum x-separation enforced between adjacent points, in curve-space [0, 1] — prevents
    /// near-vertical tangents from a near-zero-width segment.
    private let minGap: Double = 0.02

    /// How much of each drag event's raw pixel delta the *bottom* endpoint (black point) actually
    /// applies — deliberately small so it takes a much longer drag to cover the same distance the
    /// top endpoint (white point) covers in one direct jump. See `handleEndpointDrag`'s doc
    /// comment for why the two endpoints get such different feels rather than sharing one.
    private let bottomEndpointFineFactor: Double = 0.25

    /// Which sorted-index endpoint (0 or `sortedPoints.count - 1`) is currently being dragged, if
    /// any — drives `endpointDragGuide`'s vertical line, which only shows while that specific
    /// gesture is live. `nil` the rest of the time.
    @State private var draggingEndpointIndex: Int? = nil
    /// The previous drag event's raw y, for the bottom endpoint's relative-delta (not absolute-
    /// position) tracking — same "compute from the previous event, not the gesture's start"
    /// technique `MinimalSlider`'s Shift-fine-drag and friends use elsewhere in this app.
    @State private var previousEndpointDragY: CGFloat? = nil
    /// The free-dragged (circle) point's sorted index while it's being dragged — drives its
    /// enlarged accent-colored look.
    @State private var draggingPointIndex: Int? = nil
    /// Draws a drag in progress on this sorted point index without a real gesture — for
    /// `MarketingExport`'s scripted interaction videos. `nil` (the default) in the app.
    var presentedDragIndex: Int? = nil
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showHeader {
                HStack {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Click to add a point · double-click to remove")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button(action: reset) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset \(title)")
                    .disabled(isIdentity)
                }
            }

            GeometryReader { geo in
                let width = geo.size.width
                ZStack {
                    // Everything that should respect the graph's rounded bounds lives in this
                    // inner ZStack (not `Group` — a `Group`'s `.background`/`.clipShape`/`.overlay`
                    // apply separately to *each* child rather than to the composed whole, which
                    // silently clipped every piece down to its own tiny natural bounds instead of
                    // the shared graph rect; `ZStack` composes its children into one sized unit
                    // first, so modifiers chained after it apply once, to that whole union).
                    // The point handles below are a separate layer *outside* this clip — the two
                    // endpoint handles sit exactly on the x=0/x=1 boundary, and a triangle bisected
                    // by the clip edge reads as visually broken in a way a symmetric circle didn't,
                    // so handles now always render whole, on top of the bordered graph rather than
                    // half-cut-off.
                    ZStack {
                        if !showHueAxis {
                            histogramBars(width: width)
                        }
                        if showHueAxis {
                            hueBackgroundDecoration(width: width)
                        } else if showGrid {
                            gridLines(width: width)
                        }
                        if showHueAxis {
                            hueLayers(width: width)
                        } else {
                            referenceLines(width: width)
                        }
                        endpointDragGuide(width: width)
                        if showHueAxis && hueStyle == .tintedLine {
                            curveStroke(width: width, style: AnyShapeStyle(
                                LinearGradient(colors: WheelPalette.colorZonesColors, startPoint: .leading, endPoint: .trailing)
                            ), lineWidth: 2.5)
                        } else {
                            curveStroke(width: width)
                        }
                        addPointLayer(width: width)
                    }
                    .background(graphBackground)
                    .clipShape(graphClipShape)
                    // Same `uiColors.recessedTrackBackground` used above and by
                    // `MinimalSlider`/`VerticalCircleSlider`'s own track, reused here as the
                    // border stroke instead of a plain `Color.primary`-based line.
                    .overlay(graphClipShape.stroke(graphBorderColor, lineWidth: 1))

                    ForEach(sortedPoints.indices, id: \.self) { i in
                        pointHandle(at: i, width: width)
                    }
                }
            }
            .frame(height: height)

            if showHueAxis && hueStyle == .original {
                LinearGradient(colors: Self.hueSpectrum, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    private var graphClipShape: AnyShape {
        topCornersSquared
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 0))
            : AnyShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Color Zones: the graph sits on the same dark recessed fill as RGB Curve, and color only
    /// appears in two places — a hue stripe along the no-op line (as wide as the color wheels'
    /// ring, so the two read as one family), and a tint between the curve and that line wherever
    /// the curve actually boosts or cuts, like the wheels' tint glow. Hues come from
    /// `WheelPalette.colorZonesAxis`, i.e. the Lab hue the kernel really selects at each x.
    @ViewBuilder
    private var graphBackground: some View {
        if showHueAxis && hueStyle == .original {
            LinearGradient(colors: Self.hueSpectrum, startPoint: .leading, endPoint: .trailing)
                .opacity(0.55)
        } else if showHueAxis {
            switch hueBackground {
            case .recessed: uiColors.recessedTrackBackground
            case .sunken: Color.black.opacity(0.45)
            case .outline, .borderless, .cornerMarks, .hueLanes: Color.clear
            }
        } else {
            uiColors.recessedTrackBackground
        }
    }

    private var graphBorderColor: Color {
        guard showHueAxis else { return uiColors.recessedTrackBackground }
        switch hueBackground {
        case .recessed: return uiColors.recessedTrackBackground
        case .outline: return Color.white.opacity(0.12)
        case .sunken: return Color.white.opacity(0.06)
        case .borderless, .cornerMarks, .hueLanes: return .clear
        }
    }

    /// Grid/structure drawn over each `HueGraphBackground` — lighter or replaced where the box is
    /// gone, since a full grid floating in open space reads as the box again.
    @ViewBuilder
    private func hueBackgroundDecoration(width: CGFloat) -> some View {
        switch hueBackground {
        case .recessed, .sunken:
            if showGrid { gridLines(width: width) }
        case .outline:
            if showGrid { dotGrid(width: width) }
        case .borderless:
            // Short ticks at the quarter marks along the top and bottom edges only.
            Path { path in
                for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let x = min(max(CGFloat(fraction) * width, 0.5), width - 0.5)
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: 5))
                    path.move(to: CGPoint(x: x, y: height - 5)); path.addLine(to: CGPoint(x: x, y: height))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 1)
            .allowsHitTesting(false)
        case .cornerMarks:
            dotGrid(width: width)
            Canvas { context, _ in
                // Crop-mark brackets at the four corners, over the dot grid.
                let arm: CGFloat = 10
                var corners = Path()
                for (x, y, dx, dy) in [(0.5, 0.5, 1.0, 1.0), (width - 0.5, 0.5, -1.0, 1.0), (0.5, height - 0.5, 1.0, -1.0), (width - 0.5, height - 0.5, -1.0, -1.0)] {
                    corners.move(to: CGPoint(x: x + arm * dx, y: y)); corners.addLine(to: CGPoint(x: x, y: y)); corners.addLine(to: CGPoint(x: x, y: y + arm * dy))
                }
                context.stroke(corners, with: .color(.white.opacity(0.3)), lineWidth: 1)
            }
            .allowsHitTesting(false)
        case .hueLanes:
            // Six faint alternating columns, one per primary/secondary hue family (split at the
            // Lab hues between R/Y/G/C/B/M), each labeled at the top — structure from the axis's
            // own meaning instead of a neutral grid.
            let bounds: [Double] = [0, 0.13, 0.25, 0.42, 0.62, 0.8, 0.92, 1]
            let letters = ["R", "Y", "G", "C", "B", "M", "R"]
            ZStack(alignment: .topLeading) {
                ForEach(0..<7, id: \.self) { i in
                    let x0 = CGFloat(bounds[i]) * width, x1 = CGFloat(bounds[i + 1]) * width
                    Rectangle()
                        .fill(Color.white.opacity(i.isMultiple(of: 2) ? 0.035 : 0))
                        .frame(width: x1 - x0, height: height)
                        .offset(x: x0)
                    Text(letters[i])
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: x1 - x0)
                        .offset(x: x0, y: 4)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    /// Dots at every eighth-intersection — a lighter stand-in for `gridLines` on the box-less/
    /// outline-only backgrounds, where full lines read as a filled box again.
    private func dotGrid(width: CGFloat) -> some View {
        Canvas { context, _ in
            for i in 1..<8 {
                for j in 1..<8 {
                    let p = CGPoint(x: CGFloat(i) / 8 * width, y: CGFloat(j) / 8 * height)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 0.75, y: p.y - 0.75, width: 1.5, height: 1.5)), with: .color(.white.opacity(0.18)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// `.original`'s plain HSB spectrum — kept only so the old look stays comparable. Note it
    /// doesn't match the Lab hue the kernel actually selects at each x (see `HueGraphStyle`).
    private static let hueSpectrum: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0)
        .map { Color(hue: $0, saturation: Color.controlSpectrumSaturation, brightness: Color.controlSpectrumBrightness) }

    /// Per-style hue decoration, drawn under the curve stroke.
    @ViewBuilder
    private func hueLayers(width: CGFloat) -> some View {
        switch hueStyle {
        case .original:
            referenceLines(width: width)
        case .centerStripe:
            hueTintFill(width: width)
            hueCenterStripe(width: width)
        case .tintedLine:
            referenceLines(width: width)
            hueBottomStrip(width: width)
        case .eqBars:
            referenceLines(width: width)
            hueEQBars(width: width)
            hueBottomStrip(width: width)
        case .faintWash:
            LinearGradient(gradient: WheelPalette.colorZonesAxis, startPoint: .leading, endPoint: .trailing)
                .opacity(0.16)
                .allowsHitTesting(false)
            referenceLines(width: width)
            hueBottomStrip(width: width)
        case .photoStrip:
            referenceLines(width: width)
            photoHueStrip(width: width)
            hueBottomStrip(width: width)
        }
    }

    /// A 6pt hue strip inset along the graph's bottom edge — the axis key, without coloring the
    /// graph itself.
    private func hueBottomStrip(width: CGFloat) -> some View {
        LinearGradient(gradient: WheelPalette.colorZonesAxis, startPoint: .leading, endPoint: .trailing)
            .frame(width: width, height: 6)
            .position(x: width / 2, y: height - 3)
            .allowsHitTesting(false)
    }

    /// Discrete bars from the center line to the curve, each in its own hue — the "EQ" reading of
    /// Color Zones: a bar only exists where that hue is being changed.
    private func hueEQBars(width: CGFloat) -> some View {
        let spline = RGBCurveSpline(points: sortedPoints.map { (x: $0.x, y: $0.y) }, type: splineType)
        return Canvas { context, _ in
            let count = 48
            let slot = width / CGFloat(count)
            let midY = height / 2
            for i in 0..<count {
                let x = (Double(i) + 0.5) / Double(count)
                let y = (1 - CGFloat(spline.evaluate(x))) * height
                guard abs(y - midY) > 0.5 else { continue }
                let rect = CGRect(x: CGFloat(i) * slot + 1, y: min(y, midY), width: max(1, slot - 2), height: abs(y - midY))
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(WheelPalette.colorZonesColor(at: x).opacity(0.8)))
            }
        }
        .allowsHitTesting(false)
    }

    /// A hue strip lit by *this photo's* colors, stacked directly on top of the plain
    /// `hueBottomStrip` — each hue's brightness follows the hue histogram, so hues the photo
    /// doesn't contain fade out, while the full strip below still keys the whole axis.
    private func photoHueStrip(width: CGFloat) -> some View {
        Canvas { context, _ in
            let bins = histogram ?? []
            let count = bins.isEmpty ? 72 : bins.count
            let slot = width / CGFloat(count)
            for i in 0..<count {
                let x = (Double(i) + 0.5) / Double(count)
                let presence = bins.isEmpty ? 1 : Double(bins[i])
                let rect = CGRect(x: CGFloat(i) * slot, y: height - 6 - 8, width: slot + 0.5, height: 8)
                context.fill(Path(rect), with: .color(WheelPalette.colorZonesColor(at: x).opacity(0.12 + 0.88 * presence)))
            }
        }
        .allowsHitTesting(false)
    }

    private func hueCenterStripe(width: CGFloat) -> some View {
        LinearGradient(gradient: WheelPalette.colorZonesAxis, startPoint: .leading, endPoint: .trailing)
            .frame(width: width, height: 6)
            .position(x: width / 2, y: height / 2)
            .allowsHitTesting(false)
    }

    /// The region between the curve and the center line, filled with the hue at each x — so a
    /// bump over the greens glows green, and a flat curve shows no color at all beyond the stripe.
    /// Fades from strong at the curve to faint at the center line.
    private func hueTintFill(width: CGFloat) -> some View {
        let spline = RGBCurveSpline(points: sortedPoints.map { (x: $0.x, y: $0.y) }, type: splineType)
        let steps = 96
        let midY = height / 2
        let area = Path { path in
            path.move(to: CGPoint(x: 0, y: midY))
            for i in 0...steps {
                let x = Double(i) / Double(steps)
                path.addLine(to: screenPoint(for: SIMD2(x, spline.evaluate(x)), width: width))
            }
            path.addLine(to: CGPoint(x: width, y: midY))
            path.closeSubpath()
        }
        return LinearGradient(gradient: WheelPalette.colorZonesAxis, startPoint: .leading, endPoint: .trailing)
            .mask(
                area.fill(LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.55), location: 0),
                        .init(color: .white.opacity(0.12), location: 0.5),
                        .init(color: .white.opacity(0.55), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
            )
            .allowsHitTesting(false)
    }

    // MARK: - Geometry

    /// `points` is kept sorted by x by construction (see `updatePoint`/`addPoint`), so this is
    /// just a defensive re-sort in case something upstream hands in an unsorted array.
    private var sortedPoints: [SIMD2<Double>] {
        points.sorted { $0.x < $1.x }
    }

    private func screenPoint(for p: SIMD2<Double>, width: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * width, y: (1 - CGFloat(p.y)) * height)
    }

    private func curveValue(for location: CGPoint, width: CGFloat) -> SIMD2<Double> {
        let x = Double(min(max(location.x / width, 0), 1))
        let y = Double(min(max(1 - location.y / height, 0), 1))
        return SIMD2(x, y)
    }

    private var isIdentity: Bool {
        sortedPoints.count == identityPoints.count && sortedPoints == identityPoints.sorted { $0.x < $1.x }
    }

    // MARK: - Drawing

    private func referenceLines(width: CGFloat) -> some View {
        Path { path in
            if referenceIsFlat {
                let midY = height / 2
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: width, y: midY))
            } else {
                path.move(to: CGPoint(x: 0, y: height))
                path.addLine(to: CGPoint(x: width, y: 0))
            }
        }
        .stroke(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
    }

    /// Quarter-division reference lines (25/50/75% in both axes) — solid and noticeably lighter
    /// than `referenceLines`'s dashed diagonal/flat guide, so it reads as a backdrop grid rather
    /// than competing with that guide or the curve stroke itself.
    private func gridLines(width: CGFloat) -> some View {
        Path { path in
            for fraction in [0.25, 0.5, 0.75] {
                let x = CGFloat(fraction) * width
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height))
                let y = CGFloat(fraction) * height
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
        }
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    }

    /// A guide line at the dragged endpoint's fixed coordinate — shows only while
    /// `draggingEndpointIndex` is set (i.e. mid-drag on that specific point), same dashed weight
    /// `referenceLines` uses. The bottom (black point) endpoint still fixes x and slides in y, so
    /// it gets a vertical plumb line at that fixed column; the top (white point) endpoint now fixes
    /// y and slides in x instead (see `handleEndpointDrag`'s doc comment), so it gets a horizontal
    /// line at that fixed row instead.
    @ViewBuilder
    private func endpointDragGuide(width: CGFloat) -> some View {
        if let draggingEndpointIndex, draggingEndpointIndex < sortedPoints.count {
            let point = sortedPoints[draggingEndpointIndex]
            let isTopEndpoint = draggingEndpointIndex == sortedPoints.count - 1
            Path { path in
                if isTopEndpoint {
                    let y = (1 - CGFloat(point.y)) * height
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                } else {
                    let x = CGFloat(point.x) * width
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                }
            }
            .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .allowsHitTesting(false)
        }
    }

    /// Uses the same `width` parameter (and the stored `height`) as `curveStroke`/`referenceLines`
    /// rather than `Canvas`'s own `size` argument — both should already match since every ZStack
    /// sibling here is proposed the same box by the enclosing `GeometryReader`, but sharing one
    /// source of truth rules out any drift between the bars and the curve/points sitting on top
    /// of them instead of leaving it to coincidence.
    ///
    /// Tinted with `uiColors.accentColor` at a low opacity rather than a flat `Color.primary`
    /// (stark white in this app's fixed dark theme) — reads as a quiet backdrop that belongs to
    /// the same accent-colored curve line sitting on top of it, instead of an unrelated gray block.
    private func histogramBars(width: CGFloat) -> some View {
        Canvas { context, _ in
            guard let histogram, !histogram.isEmpty else { return }
            let binWidth = width / CGFloat(histogram.count)
            for (i, value) in histogram.enumerated() {
                let barHeight = CGFloat(value) * height
                let rect = CGRect(
                    x: CGFloat(i) * binWidth, y: height - barHeight,
                    width: max(1, binWidth - 0.5), height: barHeight
                )
                context.fill(Path(rect), with: .color(uiColors.accentColor.opacity(0.16)))
            }
        }
    }

    private func curveStroke(width: CGFloat, style: AnyShapeStyle? = nil, lineWidth: CGFloat = 1.5) -> some View {
        let spline = RGBCurveSpline(points: sortedPoints.map { (x: $0.x, y: $0.y) }, type: splineType)
        let steps = 96
        return Path { path in
            for i in 0...steps {
                let x = Double(i) / Double(steps)
                let y = spline.evaluate(x)
                let p = screenPoint(for: SIMD2(x, y), width: width)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        .stroke(style ?? AnyShapeStyle(lineColor), lineWidth: lineWidth)
    }

    /// Invisible full-size layer beneath the point handles; a tap here that doesn't land on an
    /// existing point (those win hit-testing since they're layered on top) adds a new one.
    private func addPointLayer(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .onTapGesture { location in
                addPoint(at: curveValue(for: location, width: width))
            }
    }

    /// Same white-circle + small-center-dot + shadow look as the color wheels' own puck
    /// (`ColorWheelControl`'s `puckDiameter`-sized `Circle` over its 3pt center dot) — one
    /// consistent "control dial" language for every draggable handle in the editor, not a plain
    /// dot here and a fuller puck there. The two endpoints switch to `EdgeTriangle` instead,
    /// mirrored so each points out of the edge it's pinned to, whenever `showEndpointControls` is
    /// on — see the struct doc comment.
    private func pointHandle(at index: Int, width: CGFloat) -> some View {
        // Structural — these two points can never be deleted, regardless of `showEndpointControls`.
        let isEndpoint = index == 0 || index == sortedPoints.count - 1
        // Only the *drag behavior* is gated: Color Zones (`showEndpointControls == false`) keeps
        // every point, endpoints included, on the plain free-drag path via `updatePoint`, same as
        // before this feature existed.
        let useEndpointDrag = isEndpoint && showEndpointControls
        let p = sortedPoints[index]
        return ZStack {
            Circle().fill(Color.clear).frame(width: 24, height: 24)
            if useEndpointDrag {
                // index == 0 is the leftmost (black) point, pinned to the graph's left edge —
                // points right, in from that edge. The rightmost (white) point is pinned to the
                // top edge — points down, in from that edge, via a 90° clockwise rotation of the
                // same right-pointing base shape.
                EdgeTriangle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(index == 0 ? 0 : 90))
                    .shadow(radius: 1)
            } else {
                // Same point style as the RGB curve (`CurveComponents`' point handles): a small
                // outlined white dot that grows and takes the accent color while dragged.
                let isDragging = (draggingPointIndex ?? presentedDragIndex) == index
                Circle()
                    .fill(isDragging ? uiColors.accentColor : Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                    .frame(width: isDragging ? 11 : 8, height: isDragging ? 11 : 8)
            }
        }
        .contentShape(Circle())
        .position(screenPoint(for: p, width: width))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if useEndpointDrag {
                        handleEndpointDrag(value, originalValue: p, isTop: index == sortedPoints.count - 1, width: width, height: height)
                    } else {
                        draggingPointIndex = index
                        updatePoint(originalValue: p, to: curveValue(for: value.location, width: width))
                    }
                }
                .onEnded { _ in
                    draggingPointIndex = nil
                    guard useEndpointDrag else { return }
                    draggingEndpointIndex = nil
                    previousEndpointDragY = nil
                }
        )
        .onTapGesture(count: 2) {
            guard !isEndpoint else { return }
            removePoint(p)
        }
    }

    // MARK: - Mutation

    /// Drives every non-endpoint point's drag, plus the endpoints themselves whenever
    /// `showEndpointControls` is off (Color Zones) — `handleEndpointDrag` only takes over for the
    /// two endpoints when it's on (RGB Curve). Clamps x to stay past its immediate neighbor (by
    /// `minGap`, so segments can't collapse to zero width) and stay inside the domain otherwise;
    /// `handleEndpointDrag` needs no such clamp since its endpoints never move in x at all.
    private func updatePoint(originalValue: SIMD2<Double>, to newValue: SIMD2<Double>) {
        guard let index = points.firstIndex(of: originalValue) else { return }
        let ordered = sortedPoints
        guard let orderedIndex = ordered.firstIndex(of: originalValue) else { return }
        let lowerBound = orderedIndex > 0 ? ordered[orderedIndex - 1].x + minGap : 0
        let upperBound = orderedIndex < ordered.count - 1 ? ordered[orderedIndex + 1].x - minGap : 1
        var updated = newValue
        updated.x = min(max(updated.x, lowerBound), upperBound)
        points[index] = updated
        onChange()
    }

    /// Drives the two endpoints' drag behavior when `showEndpointControls` is on — deliberately
    /// different from `updatePoint`'s (and from each other's) rather than sharing one path:
    /// - The *bottom* endpoint (black point) fixes x (`originalValue.x`, never reassigned — its
    ///   input position is fixed, only its output level moves) and slides in y instead, using a
    ///   relative delta from the previous drag event damped by `bottomEndpointFineFactor` — the
    ///   same "compute from the previous event" technique `MinimalSlider`'s Shift-fine-drag uses,
    ///   except here it's the endpoint's *default* feel: a small shift in the shadow output level
    ///   reads as a much bigger visual change than the same shift at the white point, so it gets
    ///   "really shallow" precision by default rather than something gated behind a modifier key.
    ///   `endpointDragGuide`'s vertical line marks its fixed column while the drag is live.
    /// - The *top* endpoint (white point, `isTop`) instead fixes y and slides in x, along the
    ///   graph's top edge — the same direct, absolute cursor-to-x mapping every non-endpoint
    ///   point's drag already uses, clamped to stay right of its neighbor by `minGap` (same clamp
    ///   `updatePoint` applies to every interior point) so it can't cross past it. `
    ///   endpointDragGuide`'s horizontal line marks its fixed row while the drag is live.
    private func handleEndpointDrag(_ drag: DragGesture.Value, originalValue: SIMD2<Double>, isTop: Bool, width: CGFloat, height: CGFloat) {
        guard let index = points.firstIndex(of: originalValue) else { return }
        let ordered = sortedPoints
        guard let orderedIndex = ordered.firstIndex(of: originalValue) else { return }

        if draggingEndpointIndex != orderedIndex { draggingEndpointIndex = orderedIndex }

        let newPoint: SIMD2<Double>
        if isTop {
            let lowerBound = orderedIndex > 0 ? ordered[orderedIndex - 1].x + minGap : 0
            let newX = min(max(Double(drag.location.x / width), lowerBound), 1)
            newPoint = SIMD2(newX, originalValue.y)
        } else {
            let previousY = previousEndpointDragY ?? drag.location.y
            let deltaY = Double((previousY - drag.location.y) / height) * bottomEndpointFineFactor
            let newY = min(max(originalValue.y + deltaY, 0), 1)
            newPoint = SIMD2(originalValue.x, newY)
        }
        previousEndpointDragY = drag.location.y

        points[index] = newPoint
        onChange()
    }

    private func addPoint(at value: SIMD2<Double>) {
        guard points.count < maxPoints else { return }
        let ordered = sortedPoints
        // Reject taps too close to an existing point in x — avoids creating a degenerate,
        // near-zero-width segment right next to one that already exists.
        guard ordered.allSatisfy({ abs($0.x - value.x) > minGap }) else { return }
        points.append(value)
        onChange()
    }

    private func removePoint(_ value: SIMD2<Double>) {
        guard points.count > 2 else { return }
        points.removeAll { $0 == value }
        onChange()
    }

    private func reset() {
        points = identityPoints
        onChange()
    }
}

/// A small triangle pointing right (apex on the trailing edge, flat base on the leading edge) —
/// `pointHandle` rotates it per endpoint (0° for the left-edge black point, 90° clockwise for the
/// top-edge white point, which turns "points right" into "points down") rather than giving each
/// its own path.
private struct EdgeTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
