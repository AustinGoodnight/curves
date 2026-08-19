import SwiftUI
import RawEngine

/// A Lightroom/Photoshop-style tone curve editor: drag existing points, click empty graph space
/// to add a new one (up to `RGBCurveKernel.maxNodes`), double-click an interior point to remove
/// it. The two endpoints are always present and locked to x = 0 / x = 1 (the curve's domain is
/// fixed to the full input range — only their height is adjustable) — interior points are free
/// to move in both axes, clamped between their immediate neighbors so the curve can't fold back
/// on itself.
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
    /// Draws a full-saturation hue spectrum strip below the graph — Color Zones' x-axis *is* hue
    /// (0...1 mapping to 0°...360°), so this lets the user see which colors a given x-position
    /// actually affects instead of reading it off the numeric axis. RGB Curve's x-axis is input
    /// tone, not hue, so this stays off there.
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
    var onChange: () -> Void = {}

    /// Minimum x-separation enforced between adjacent points, in curve-space [0, 1] — prevents
    /// near-vertical tangents from a near-zero-width segment.
    private let minGap: Double = 0.02

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
                    histogramBars(width: width)
                    referenceLines(width: width)
                    curveStroke(width: width)
                    addPointLayer(width: width)
                    ForEach(sortedPoints.indices, id: \.self) { i in
                        pointHandle(at: i, width: width)
                    }
                }
                .background(Color.primary.opacity(0.05))
                .clipShape(graphClipShape)
            }
            .frame(height: height)

            if showHueAxis {
                hueAxisStrip
            }
        }
    }

    private var graphClipShape: AnyShape {
        topCornersSquared
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 4, bottomTrailingRadius: 4, topTrailingRadius: 0))
            : AnyShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Full-saturation spectrum, both ends red — hue wraps at 0°/360°, so a `LinearGradient` with
    /// matching colors at x = 0 and x = 1 reads correctly against the graph's own [0, 1] domain.
    private static let hueSpectrum: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0)
        .map { Color(hue: $0, saturation: 0.85, brightness: 0.95) }

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
        .stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func histogramBars(width: CGFloat) -> some View {
        Canvas { context, size in
            guard let histogram, !histogram.isEmpty else { return }
            let binWidth = size.width / CGFloat(histogram.count)
            for (i, value) in histogram.enumerated() {
                let barHeight = CGFloat(value) * size.height
                let rect = CGRect(
                    x: CGFloat(i) * binWidth, y: size.height - barHeight,
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
        .stroke(Color.accentColor, lineWidth: 1.5)
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

    private func pointHandle(at index: Int, width: CGFloat) -> some View {
        let isEndpoint = index == 0 || index == sortedPoints.count - 1
        let p = sortedPoints[index]
        return ZStack {
            Circle().fill(Color.clear).frame(width: 22, height: 22)
            Circle()
                .fill(Color.white)
                .frame(width: 9, height: 9)
                .shadow(radius: 1)
        }
        .contentShape(Circle())
        .position(screenPoint(for: p, width: width))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    updatePoint(originalValue: p, isEndpoint: isEndpoint, to: curveValue(for: value.location, width: width))
                }
        )
        .onTapGesture(count: 2) {
            guard !isEndpoint else { return }
            removePoint(p)
        }
    }

    // MARK: - Mutation

    private func updatePoint(originalValue: SIMD2<Double>, isEndpoint: Bool, to newValue: SIMD2<Double>) {
        guard let index = points.firstIndex(of: originalValue) else { return }
        var updated = newValue
        if isEndpoint {
            updated.x = originalValue.x
        } else {
            let ordered = sortedPoints
            guard let orderedIndex = ordered.firstIndex(of: originalValue) else { return }
            let lowerBound = ordered[orderedIndex - 1].x + minGap
            let upperBound = ordered[orderedIndex + 1].x - minGap
            updated.x = min(max(updated.x, lowerBound), upperBound)
        }
        points[index] = updated
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
