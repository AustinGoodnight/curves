import SwiftUI
import RawEngine

/// A Lightroom/Photoshop-style tone curve editor: drag existing points, click empty graph space
/// to add a new one (up to `RGBCurveKernel.maxNodes`), double-click an interior point to remove
/// it. The two endpoints are always present and can't be removed. Interior points drag freely in
/// both axes; when `showEndpointControls` is on, the two endpoints instead lock x for the
/// duration of a drag and move in y only (their input stays fixed; only their output level
/// changes) — see `handleEndpointDrag`'s doc comment for why, and for why the two endpoints don't
/// even move at the same y speed as each other. `showEndpointControls` also adds a dedicated
/// slider along the left edge (black point output) and the top edge (white point output) as an
/// easier way to make the same adjustment than grabbing the small point handle directly.
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
    /// Tints the graph's own background with a full-saturation hue spectrum — Color Zones' x-axis
    /// *is* hue (0...1 mapping to 0°...360°), so this lets the user see which colors a given
    /// x-position actually affects instead of reading it off the numeric axis. RGB Curve's x-axis
    /// is input tone, not hue, so this stays off there.
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
    var onChange: () -> Void = {}

    /// Minimum x-separation enforced between adjacent points, in curve-space [0, 1] — prevents
    /// near-vertical tangents from a near-zero-width segment.
    private let minGap: Double = 0.02

    /// How much of each drag event's raw pixel delta the *bottom* endpoint (black point) actually
    /// applies — deliberately small so it takes a much longer drag to cover the same distance the
    /// top endpoint (white point) covers in one direct jump. See `handleEndpointDrag`'s doc
    /// comment for why the two endpoints get such different feels rather than sharing one.
    private let bottomEndpointFineFactor: Double = 0.25

    /// Width of the dedicated black-point slider along the left edge (and, to keep the top
    /// slider's own track aligned with the graph rather than starting under that left slider, the
    /// width of the leading spacer reserved above it too).
    private let endpointSliderThickness: CGFloat = 24

    /// Which sorted-index endpoint (0 or `sortedPoints.count - 1`) is currently being dragged, if
    /// any — drives `endpointDragGuide`'s vertical line, which only shows while that specific
    /// gesture is live. `nil` the rest of the time.
    @State private var draggingEndpointIndex: Int? = nil
    /// The previous drag event's raw y, for the bottom endpoint's relative-delta (not absolute-
    /// position) tracking — same "compute from the previous event, not the gesture's start"
    /// technique `MinimalSlider`'s Shift-fine-drag and friends use elsewhere in this app.
    @State private var previousEndpointDragY: CGFloat? = nil

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

            // Dedicated white-point-output slider along the top edge — an easier way to make the
            // same adjustment `handleEndpointDrag`'s "quick" top-endpoint drag makes, without
            // having to land the cursor on the small point handle itself. The leading spacer
            // matches `endpointSliderThickness` so this track starts above the *graph's* own
            // left edge, not above the black-point slider sitting to the graph's left below it.
            if showEndpointControls {
                HStack(spacing: 8) {
                    Color.clear.frame(width: endpointSliderThickness)
                    MinimalSlider(value: whitePointYBinding, range: 0...1, resetValue: identityPoints.last?.y ?? 1)
                }
            }

            HStack(spacing: 8) {
                // Dedicated black-point-output slider along the left edge — same idea as the top
                // slider above, for the "shallow" bottom endpoint.
                if showEndpointControls {
                    VerticalCircleSlider(value: blackPointYBinding, range: 0...1, resetValue: identityPoints.first?.y ?? 0)
                        .frame(width: endpointSliderThickness, height: height)
                }

                GeometryReader { geo in
                    let width = geo.size.width
                    ZStack {
                        if !showHueAxis {
                            histogramBars(width: width)
                        }
                        if showGrid {
                            gridLines(width: width)
                        }
                        referenceLines(width: width)
                        endpointDragGuide(width: width)
                        curveStroke(width: width)
                        addPointLayer(width: width)
                        ForEach(sortedPoints.indices, id: \.self) { i in
                            pointHandle(at: i, width: width)
                        }
                    }
                    .background(graphBackground)
                    .clipShape(graphClipShape)
                    .overlay(graphClipShape.stroke(Color.primary.opacity(0.2), lineWidth: 1))
                }
                .frame(height: height)
            }

            if showHueAxis {
                hueAxisStrip
            }
        }
    }

    /// Reads/writes the black point's (leftmost sorted point's) own y — backs the left-edge
    /// slider `showEndpointControls` adds. A computed `Binding` rather than a stored one since
    /// the underlying point's *index* in `points` can change (`sortedPoints` re-sorts on every
    /// edit) even though it's always `sortedPoints.first`.
    private var blackPointYBinding: Binding<Double> {
        Binding(
            get: { sortedPoints.first?.y ?? 0 },
            set: { newY in
                guard let first = sortedPoints.first, let idx = points.firstIndex(of: first) else { return }
                points[idx] = SIMD2(first.x, newY)
                onChange()
            }
        )
    }

    /// The white point's (rightmost sorted point's) own y — see `blackPointYBinding`.
    private var whitePointYBinding: Binding<Double> {
        Binding(
            get: { sortedPoints.last?.y ?? 1 },
            set: { newY in
                guard let last = sortedPoints.last, let idx = points.firstIndex(of: last) else { return }
                points[idx] = SIMD2(last.x, newY)
                onChange()
            }
        )
    }

    private var graphClipShape: AnyShape {
        topCornersSquared
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 0))
            : AnyShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Full-saturation spectrum, both ends red — hue wraps at 0°/360°, so a `LinearGradient` with
    /// matching colors at x = 0 and x = 1 reads correctly against the graph's own [0, 1] domain.
    private static let hueSpectrum: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0)
        .map { Color(hue: $0, saturation: 0.85, brightness: 0.95) }

    /// Color Zones gets the spectrum; RGB Curve gets no fill at all — it now sits directly on
    /// whatever background it's placed against (the sidebar's own) rather than a lighter panel
    /// color, with `graphClipShape.stroke(...)` (see above) as the only thing marking its bounds.
    @ViewBuilder
    private var graphBackground: some View {
        if showHueAxis {
            LinearGradient(colors: Self.hueSpectrum, startPoint: .leading, endPoint: .trailing)
                .opacity(0.55)
        } else {
            Color.clear
        }
    }

    private var hueAxisStrip: some View {
        LinearGradient(colors: Self.hueSpectrum, startPoint: .leading, endPoint: .trailing)
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3))
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

    /// A plumb line at the dragged endpoint's fixed input (x) position, spanning the full graph
    /// height — shows only while `draggingEndpointIndex` is set (i.e. mid-drag on that specific
    /// point), same dashed weight `referenceLines` uses. `handleEndpointDrag` never reassigns that
    /// endpoint's x for the duration of the drag, so this line's own x stays put too — it marks
    /// the fixed column the point is sliding up/down within, not something that itself moves.
    @ViewBuilder
    private func endpointDragGuide(width: CGFloat) -> some View {
        if let draggingEndpointIndex, draggingEndpointIndex < sortedPoints.count {
            let x = CGFloat(sortedPoints[draggingEndpointIndex].x) * width
            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height))
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
                context.fill(Path(rect), with: .color(Color.primary.opacity(0.12)))
            }
        }
    }

    private func curveStroke(width: CGFloat) -> some View {
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
        .stroke(lineColor, lineWidth: 1.5)
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
    /// dot here and a fuller puck there.
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
            Circle()
                .fill(Color.white)
                .frame(width: 13, height: 13)
                .shadow(radius: 1)
            Circle()
                .fill(Color.primary.opacity(0.4))
                .frame(width: 3, height: 3)
        }
        .contentShape(Circle())
        .position(screenPoint(for: p, width: width))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if useEndpointDrag {
                        handleEndpointDrag(value, originalValue: p, isTop: index == sortedPoints.count - 1, height: height)
                    } else {
                        updatePoint(originalValue: p, to: curveValue(for: value.location, width: width))
                    }
                }
                .onEnded { _ in
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
    /// - x stays exactly where it already was (`originalValue.x`, never reassigned) — the
    ///   endpoint's input position is fixed, only its output level moves. `endpointDragGuide`'s
    ///   vertical line marks that fixed column while the drag is live.
    /// - y itself moves at two deliberately different speeds. The *top* endpoint (white point,
    ///   `isTop`) uses the same absolute cursor-to-y mapping every non-endpoint point already
    ///   uses — direct, immediate, "quick." The *bottom* endpoint (black point) instead uses a
    ///   relative delta from the previous drag event, damped by `bottomEndpointFineFactor`, the
    ///   same "compute from the previous event" technique `MinimalSlider`'s Shift-fine-drag uses —
    ///   except here it's the endpoint's *default* feel, not something gated behind a modifier
    ///   key, since the black point is the one that benefits from "really shallow" precision by
    ///   default (a small shift in the shadow output level reads as a much bigger visual change
    ///   than the same shift does at the white point).
    private func handleEndpointDrag(_ drag: DragGesture.Value, originalValue: SIMD2<Double>, isTop: Bool, height: CGFloat) {
        guard let index = points.firstIndex(of: originalValue) else { return }
        guard let orderedIndex = sortedPoints.firstIndex(of: originalValue) else { return }

        if draggingEndpointIndex != orderedIndex { draggingEndpointIndex = orderedIndex }

        let newY: Double
        if isTop {
            newY = min(max(Double(1 - drag.location.y / height), 0), 1)
        } else {
            let previousY = previousEndpointDragY ?? drag.location.y
            let deltaY = Double((previousY - drag.location.y) / height) * bottomEndpointFineFactor
            newY = min(max(originalValue.y + deltaY, 0), 1)
        }
        previousEndpointDragY = drag.location.y

        points[index] = SIMD2(originalValue.x, newY)
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
