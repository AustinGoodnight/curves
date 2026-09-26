import SwiftUI
import AppKit
import RawEngine

/// Building blocks for the RGB Curve editor — used by the real editor (`CurveWorkbench`) and by
/// the Developer Mode comparison concepts (`CurveEditorConcepts.swift`). Everything edits a plain
/// `Binding<[SIMD2<Double>]>` of curve points, draws with the renderer's own spline
/// (`RGBCurveSpline`, monotone Hermite, so what's drawn is what renders), and respects the
/// kernel's `RGBCurveKernel.maxNodes` point limit.

// MARK: - Curve math

let curveMaxPoints = RGBCurveKernel.maxNodes

func clampUnit(_ v: Double) -> Double { min(max(v, 0), 1) }

/// Sorted copy of `points`. Endpoints are *not* forced to x = 0/1: an endpoint moved in along
/// the bottom/top edge (`CurveEdgeHandles`) is a valid input black/white point — both the spline
/// and `RGBCurveKernel` clamp input to the node range, so tones outside it render flat at the
/// endpoint's level.
func normalizedCurve(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
    let sorted = points.sorted { $0.x < $1.x }
    guard sorted.count >= 2 else { return RGBCurveParameters.identityPoints }
    return sorted
}

/// The x range a new interior point may be placed in — strictly between the endpoints, which may
/// themselves have moved in from 0/1.
func interiorRange(_ current: [SIMD2<Double>], margin: Double = 0.02) -> ClosedRange<Double> {
    let lower = (current.first?.x ?? 0) + margin
    let upper = (current.last?.x ?? 1) - margin
    return lower <= upper ? lower...upper : lower...lower
}

func curveSpline(_ points: [SIMD2<Double>]) -> RGBCurveSpline {
    RGBCurveSpline(points: normalizedCurve(points).map { (x: $0.x, y: $0.y) }, type: .monotoneHermite)
}

/// Share (0...1) of the photo's pixels within ±`halfWidth` of tone `x`, from a normalized
/// histogram (counts are relative, so only the ratio is meaningful — which is all this needs).
func histogramShare(_ histogram: [Float], around x: Double, halfWidth: Double = 0.05) -> Double {
    let total = histogram.reduce(0, +)
    guard histogram.count > 1, total > 0 else { return 0 }
    var sum: Float = 0
    for (i, v) in histogram.enumerated() {
        let center = (Double(i) + 0.5) / Double(histogram.count)
        if abs(center - x) <= halfWidth { sum += v }
    }
    return Double(sum / total)
}

/// Ansel Adams zones on the curve's display-referred 0...1 axes — one stop apart, Zone V at 18%
/// grey, same 2.2-gamma stops placement as the Zones scope (`PhotoDataPanel`).
enum CurveZones {
    static let numerals = ["0", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]

    /// Display value (0...1) at `zone` (fractional zones allowed — `zone - 0.5` is a boundary).
    static func displayValue(zone: Double) -> Double {
        clampUnit(pow(0.18 * pow(2, zone - 5), 1 / 2.2))
    }

    static func zone(ofDisplay v: Double) -> Double {
        5 + log2(max(pow(max(v, 1e-4), 2.2), 1e-6) / 0.18)
    }

    static func numeral(ofDisplay v: Double) -> String {
        numerals[Int(min(max(zone(ofDisplay: v).rounded(), 0), 10))]
    }

    /// Nearest zone center to `x`.
    static func snapped(_ x: Double) -> Double {
        displayValue(zone: min(max(zone(ofDisplay: x).rounded(), 0), 10))
    }
}

// MARK: - Backdrop

/// The graph: recessed panel, histogram, grid, identity diagonal, and the curve itself.
struct CurveBackdrop: View {
    enum Grid { case none, quarters, zones }

    let points: [SIMD2<Double>]
    let histogram: [Float]
    var lineColor: Color = .white
    var grid: Grid = .quarters
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(uiColors.recessedTrackBackground))
            if histogram.count > 1 {
                var hist = Path()
                hist.move(to: CGPoint(x: 0, y: h))
                for (i, v) in histogram.enumerated() {
                    hist.addLine(to: CGPoint(x: w * (CGFloat(i) + 0.5) / CGFloat(histogram.count), y: h - h * CGFloat(v) * 0.9))
                }
                hist.addLine(to: CGPoint(x: w, y: h))
                hist.closeSubpath()
                context.fill(hist, with: .color(.white.opacity(0.09)))
            }
            switch grid {
            case .none:
                break
            case .quarters:
                var lines = Path()
                for q in [0.25, 0.5, 0.75] {
                    lines.move(to: CGPoint(x: w * q, y: 0)); lines.addLine(to: CGPoint(x: w * q, y: h))
                    lines.move(to: CGPoint(x: 0, y: h * q)); lines.addLine(to: CGPoint(x: w, y: h * q))
                }
                context.stroke(lines, with: .color(.white.opacity(0.05)), lineWidth: 1)
            case .zones:
                // Zone boundaries on both axes; the two around middle grey (V) a little stronger.
                for zone in 1..<11 {
                    let v = CurveZones.displayValue(zone: Double(zone) - 0.5)
                    var line = Path()
                    line.move(to: CGPoint(x: w * v, y: 0)); line.addLine(to: CGPoint(x: w * v, y: h))
                    line.move(to: CGPoint(x: 0, y: h * (1 - v))); line.addLine(to: CGPoint(x: w, y: h * (1 - v)))
                    context.stroke(line, with: .color(.white.opacity(zone == 5 || zone == 6 ? 0.1 : 0.045)), lineWidth: 1)
                }
            }
            var diagonal = Path()
            diagonal.move(to: CGPoint(x: 0, y: h)); diagonal.addLine(to: CGPoint(x: w, y: 0))
            context.stroke(diagonal, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let curve = curveSpline(points)
            var line = Path()
            for i in 0...120 {
                let x = Double(i) / 120
                let point = CGPoint(x: w * x, y: h - h * clampUnit(curve.evaluate(x)))
                if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(lineColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        // Same 8pt rounded corners as every other recessed panel — clips the histogram, grid and
        // curve too, not just the fill.
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Zone numerals (0–X) positioned under the graph at each zone's center — Zone V bold.
struct CurveZoneAxisLabels: View {
    var body: some View {
        GeometryReader { geo in
            ForEach(0..<11, id: \.self) { zone in
                Text(CurveZones.numerals[zone])
                    .font(.system(size: 8, weight: zone == 5 ? .bold : .regular))
                    .foregroundStyle(zone == 5 ? Color.primary : Color.secondary)
                    .fixedSize()
                    .position(x: min(max(geo.size.width * CurveZones.displayValue(zone: Double(zone)), 4), geo.size.width - 6), y: 5)
            }
        }
        .frame(height: 10)
    }
}

// MARK: - Point editor

/// Drag-to-edit graph with visible points. Drag near a point to move it (Shift = fine); drag
/// elsewhere to add one there (up to `curveMaxPoints`); double-click a point to remove it.
/// Endpoints stay pinned at x = 0 and 1 (their y still moves — black/white output levels).
/// `focusX` reports the point being dragged or the hovered tone, for an outside readout.
struct PointCurveEditor: View {
    @Binding var points: [SIMD2<Double>]
    let histogram: [Float]
    var height: CGFloat = 170
    /// Maps a raw x to where a new/moved point should land (e.g. zone centers). Identity if nil.
    var snapX: ((Double) -> Double)? = nil
    var pointsOnlyOnHover = false
    var showsReadout = false
    var snapsToDiagonal = false
    var hitRadius: CGFloat = 12
    var grid: CurveBackdrop.Grid = .quarters
    /// Readout text formatter (input, output) → label; defaults to 0–100 values.
    var readout: ((Double, Double) -> String)? = nil
    var focusX: Binding<Double?>? = nil
    /// `false` when `CurveEdgeHandles` owns the endpoints (drawn and dragged there instead).
    var editsEndpoints = true
    @Environment(ColorSchemeStore.self) private var uiColors

    @State private var dragIndex: Int?
    @State private var dragStart: SIMD2<Double>?
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let current = normalizedCurve(points)
            ZStack(alignment: .topLeading) {
                CurveBackdrop(points: current, histogram: histogram, lineColor: uiColors.accentColor, grid: grid)
                if !pointsOnlyOnHover || hover != nil || dragIndex != nil {
                    ForEach(editsEndpoints ? Array(current.indices) : Array(current.indices.dropFirst().dropLast()), id: \.self) { i in
                        let p = current[i]
                        Circle()
                            .fill(dragIndex == i ? uiColors.accentColor : .white)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                            .frame(width: dragIndex == i ? 11 : 8, height: dragIndex == i ? 11 : 8)
                            .position(x: size.width * p.x, y: size.height * (1 - p.y))
                    }
                }
                if showsReadout, let index = dragIndex, current.indices.contains(index) {
                    let p = current[index]
                    Text(readout?(p.x, p.y) ?? "\(Int((p.x * 100).rounded())) → \(Int((p.y * 100).rounded()))")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: Capsule())
                        .fixedSize()
                        .position(
                            x: min(max(size.width * p.x, 40), size.width - 40),
                            y: max(size.height * (1 - p.y) - 18, 10)
                        )
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let location) = phase {
                    hover = location
                    if dragIndex == nil { focusX?.wrappedValue = clampUnit(location.x / size.width) }
                } else {
                    hover = nil
                    if dragIndex == nil { focusX?.wrappedValue = nil }
                }
            }
            .gesture(dragGesture(size: size))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                removePoint(near: tap.location, size: size)
            })
        }
        .frame(height: height)
    }

    private func nearestIndex(to location: CGPoint, in current: [SIMD2<Double>], size: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in current.enumerated() {
            if !editsEndpoints, i == 0 || i == current.count - 1 { continue }
            let d = hypot(size.width * p.x - location.x, size.height * (1 - p.y) - location.y)
            if d <= hitRadius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                var current = normalizedCurve(points)
                if dragIndex == nil {
                    if let hit = nearestIndex(to: drag.startLocation, in: current, size: size) {
                        dragIndex = hit
                    } else if current.count < curveMaxPoints {
                        let rawX = clampUnit(drag.startLocation.x / size.width)
                        let range = interiorRange(current, margin: 0.01)
                        let x = min(max(snapX?(rawX) ?? rawX, range.lowerBound), range.upperBound)
                        guard !current.contains(where: { abs($0.x - x) < 0.01 }) else { return }
                        let y = clampUnit(curveSpline(current).evaluate(x))
                        current.append(SIMD2(x, y))
                        current.sort { $0.x < $1.x }
                        dragIndex = current.firstIndex { $0.x == x }
                        points = current
                    } else {
                        return
                    }
                    dragStart = dragIndex.map { current[$0] }
                }
                guard let index = dragIndex, let start = dragStart, current.indices.contains(index) else { return }
                let fine = NSEvent.modifierFlags.contains(.shift) ? 0.25 : 1
                var x = start.x + Double(drag.translation.width / size.width) * fine
                var y = clampUnit(start.y - Double(drag.translation.height / size.height) * fine)
                if index == 0 { x = start.x } else if index == current.count - 1 { x = start.x } else {
                    let lower = current[index - 1].x + 0.01, upper = current[index + 1].x - 0.01
                    x = min(max(snapX?(x) ?? x, lower), upper)
                }
                if snapsToDiagonal, abs(y - x) < 0.02 { y = x }
                current[index] = SIMD2(x, y)
                points = current
                focusX?.wrappedValue = x
            }
            .onEnded { _ in
                dragIndex = nil
                dragStart = nil
            }
    }

    private func removePoint(near location: CGPoint, size: CGSize) {
        var current = normalizedCurve(points)
        guard let index = nearestIndex(to: location, in: current, size: size),
              index != 0, index != current.count - 1 else { return }
        current.remove(at: index)
        points = current
    }
}

// MARK: - Targeted drag graph

/// No points to find: hover to see which tone you're over, drag up/down to lift or lower *that*
/// tone — the nearest existing point is picked up, or one is created under the cursor. Only a
/// real vertical drag creates a point (a plain click doesn't). `focusX` reports the hovered/
/// dragged tone for an outside readout.
struct TargetedCurveGraph: View {
    @Binding var points: [SIMD2<Double>]
    let histogram: [Float]
    var height: CGFloat = 170
    var grid: CurveBackdrop.Grid = .quarters
    var focusX: Binding<Double?>? = nil
    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var hoverX: Double?
    @State private var dragIndex: Int?
    @State private var dragStartY: Double?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let current = normalizedCurve(points)
            ZStack(alignment: .topLeading) {
                CurveBackdrop(points: current, histogram: histogram, lineColor: uiColors.accentColor, grid: grid)
                if let x = dragIndex.map({ current[$0].x }) ?? hoverX {
                    let y = clampUnit(curveSpline(current).evaluate(x))
                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: size.height)
                        .offset(x: size.width * x)
                    Circle().fill(.white).frame(width: 9, height: 9)
                        .position(x: size.width * x, y: size.height * (1 - y))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let location) = phase {
                    hoverX = clampUnit(location.x / size.width)
                } else {
                    hoverX = nil
                }
                if dragIndex == nil { focusX?.wrappedValue = hoverX }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                var current = normalizedCurve(points)
                if dragIndex == nil {
                    guard abs(drag.translation.height) > 2 else { return }
                    let range = interiorRange(current)
                    let x = min(max(clampUnit(drag.startLocation.x / size.width), range.lowerBound), range.upperBound)
                    if let near = current.indices.dropFirst().dropLast().min(by: { abs(current[$0].x - x) < abs(current[$1].x - x) }),
                       abs(current[near].x - x) < 0.06 {
                        dragIndex = near
                    } else if current.count < curveMaxPoints {
                        current.append(SIMD2(x, clampUnit(curveSpline(current).evaluate(x))))
                        current.sort { $0.x < $1.x }
                        dragIndex = current.firstIndex { $0.x == x }
                    } else { return }
                    dragStartY = dragIndex.map { current[$0].y }
                }
                guard let index = dragIndex, let startY = dragStartY, current.indices.contains(index) else { return }
                let fine = NSEvent.modifierFlags.contains(.shift) ? 0.25 : 1
                current[index].y = clampUnit(startY - Double(drag.translation.height / size.height) * fine)
                points = current
                focusX?.wrappedValue = current[index].x
            }.onEnded { _ in
                dragIndex = nil
                dragStartY = nil
            })
        }
        .frame(height: height)
    }
}

// MARK: - Edge handles

/// The curve's two endpoints as handles that travel along the graph's edges — the black point on
/// the L of the bottom + left edges, the white point on the L of the top + right edges:
/// - black along the **bottom** edge → input black point (tones below it crush to black);
/// - black up the **left** edge → output black level (lifted / faded shadows);
/// - white along the **top** edge → input white point (tones above it clip to white);
/// - white down the **right** edge → output white level (muted highlights).
/// A drag is projected onto whichever leg of the L it's nearer, so rounding the corner is one
/// continuous motion. Overlaid on top of the graph so these win over the graph's own gestures.
struct CurveEdgeHandles: View {
    @Binding var points: [SIMD2<Double>]
    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var active: Int?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let current = normalizedCurve(points)
            ZStack(alignment: .topLeading) {
                handle(index: 0, current: current, size: size, fill: .black, stroke: .white)
                handle(index: current.count - 1, current: current, size: size, fill: .white, stroke: .black.opacity(0.6))
                if let active, current.indices.contains(active) {
                    let p = current[active]
                    Text(label(for: p, isBlack: active == 0))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: Capsule())
                        .fixedSize()
                        .position(
                            x: min(max(size.width * p.x, 44), size.width - 44),
                            y: active == 0 ? size.height * (1 - p.y) - 18 : size.height * (1 - p.y) + 18
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func handle(index: Int, current: [SIMD2<Double>], size: CGSize, fill: Color, stroke: Color) -> some View {
        let p = current[index]
        let isActive = active == index
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(stroke, lineWidth: 1.5))
            .frame(width: isActive ? 13 : 11, height: isActive ? 13 : 11)
            .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            // Gestures before `.position` — attached after it, the gesture's hit area would be the
            // whole graph (`.position` fills its parent), swallowing every drag meant for the curve.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { drag in
                active = index
                var current = normalizedCurve(points)
                guard current.indices.contains(index) else { return }
                let fine = NSEvent.modifierFlags.contains(.shift) ? 0.25 : 1
                let base = current[index]
                let dx = Double(drag.translation.width / size.width) * fine
                let dy = -Double(drag.translation.height / size.height) * fine
                let startX = dragOrigin?.x ?? base.x, startY = dragOrigin?.y ?? base.y
                if dragOrigin == nil { dragOrigin = base }
                var x = clampUnit(startX + dx), y = clampUnit(startY + dy)
                if index == 0 {
                    // Bottom leg (y = 0) or left leg (x = 0), whichever the drag is nearer.
                    if x >= y { y = 0 } else { x = 0 }
                    if current.count > 1 { x = min(x, current[1].x - 0.02) }
                    y = min(y, 0.95)
                } else {
                    // Top leg (y = 1) or right leg (x = 1).
                    if (1 - x) >= (1 - y) { y = 1 } else { x = 1 }
                    x = max(x, current[index - 1].x + 0.02)
                    y = max(y, 0.05)
                }
                current[index] = SIMD2(clampUnit(x), clampUnit(y))
                points = current
            }.onEnded { _ in
                active = nil
                dragOrigin = nil
            })
            .onTapGesture(count: 2) {
                var current = normalizedCurve(points)
                current[index] = index == 0 ? SIMD2(0, 0) : SIMD2(1, 1)
                points = current
            }
            .help(index == 0
                  ? "Black point — drag along the bottom to crush shadows, up the left edge to lift them. Double-click resets."
                  : "White point — drag along the top to clip highlights, down the right edge to mute them. Double-click resets.")
            .position(x: size.width * p.x, y: size.height * (1 - p.y))
    }

    @State private var dragOrigin: SIMD2<Double>?

    private func label(for p: SIMD2<Double>, isBlack: Bool) -> String {
        if isBlack {
            return p.x > 0.001 ? "Black in \(Int((p.x * 100).rounded()))" : "Black out \(Int((p.y * 100).rounded()))"
        }
        return p.x < 0.999 ? "White in \(Int((p.x * 100).rounded()))" : "White out \(Int((p.y * 100).rounded()))"
    }
}

// MARK: - Ramp strip

/// Input grey ramp → the same ramp through the curve, with lines joining each tone to where it
/// lands: fanning apart = more contrast in that range, bunching = less.
struct CurveRampStrip: View {
    let points: [SIMD2<Double>]
    var height: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let curve = curveSpline(points)
            let rampHeight: CGFloat = 8
            let gap = geo.size.height - rampHeight * 2
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                    .frame(height: rampHeight).clipShape(RoundedRectangle(cornerRadius: 2))
                Path { p in
                    for i in 1..<16 {
                        let t = Double(i) / 16
                        p.move(to: CGPoint(x: t * w, y: rampHeight))
                        p.addLine(to: CGPoint(x: clampUnit(curve.evaluate(t)) * w, y: rampHeight + gap))
                    }
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                LinearGradient(
                    stops: (0...16).map { i in
                        let t = Double(i) / 16
                        return .init(color: Color(white: clampUnit(curve.evaluate(t))), location: t)
                    },
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: rampHeight).clipShape(RoundedRectangle(cornerRadius: 2))
                .offset(y: rampHeight + gap)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Presets

/// Common curve shapes as chips (each draws its own shape) plus an Amount slider that blends the
/// chosen shape's points toward straight.
struct CurvePresetChips: View {
    @Binding var points: [SIMD2<Double>]
    @State private var selected: Int?
    @State private var amount = 1.0

    static let presets: [(name: String, points: [SIMD2<Double>])] = [
        ("Linear", [SIMD2(0, 0), SIMD2(1, 1)]),
        ("Soft Contrast", [SIMD2(0, 0), SIMD2(0.25, 0.21), SIMD2(0.75, 0.79), SIMD2(1, 1)]),
        ("Strong Contrast", [SIMD2(0, 0), SIMD2(0.25, 0.16), SIMD2(0.75, 0.85), SIMD2(1, 1)]),
        ("Fade", [SIMD2(0, 0.08), SIMD2(0.5, 0.52), SIMD2(1, 0.95)]),
        ("Matte", [SIMD2(0, 0.12), SIMD2(0.2, 0.2), SIMD2(0.7, 0.74), SIMD2(1, 1)]),
        ("Brighten", [SIMD2(0, 0), SIMD2(0.4, 0.5), SIMD2(1, 1)]),
        ("Darken", [SIMD2(0, 0), SIMD2(0.6, 0.5), SIMD2(1, 1)]),
        ("Crush Blacks", [SIMD2(0, 0), SIMD2(0.12, 0.03), SIMD2(0.5, 0.5), SIMD2(1, 1)]),
    ]

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Self.presets.indices, id: \.self) { i in
                    chip(i)
                }
            }
            slider("Amount", value: Binding(get: { amount }, set: { amount = $0; apply() }),
                   range: 0...1, resetValue: 1, ticks: [0, 0.5, 1], trackStyle: .hairline, thumbShape: .diamond)
                .disabled(selected == nil)
                .opacity(selected == nil ? 0.4 : 1)
        }
    }

    private func chip(_ index: Int) -> some View {
        let preset = Self.presets[index]
        let isSelected = selected == index
        return VStack(spacing: 3) {
            Canvas { context, size in
                let curve = curveSpline(preset.points)
                var line = Path()
                for i in 0...30 {
                    let x = Double(i) / 30
                    let point = CGPoint(x: size.width * x, y: size.height * (1 - clampUnit(curve.evaluate(x))))
                    if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                context.stroke(line, with: .color(isSelected ? .white : .white.opacity(0.55)), lineWidth: 1.5)
            }
            .frame(height: 26)
            .padding(4)
            .background(Color.white.opacity(isSelected ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 5))
            Text(preset.name)
                .font(.system(size: 8))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selected = index
            amount = 1
            apply()
        }
    }

    private func apply() {
        guard let selected else { return }
        points = Self.presets[selected].points.map { p in SIMD2(p.x, p.x + (p.y - p.x) * amount) }
    }
}
