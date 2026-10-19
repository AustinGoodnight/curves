import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import RawEngine

/// Off-screen, high-resolution renders of the editor's controls and panels for the website —
/// sharper than any screenshot because each scene is drawn straight through `ImageRenderer` at
/// `scale`x (4x by default), never through a window.
///
/// Triggered by launching the app with `--export-marketing <dir>` (see `Tools/export-marketing.sh`). Optional flags:
/// `--marketing-photo <path>` drives every histogram/scope/hue backdrop and the Detail close-up
/// from a real photo (synthetic data otherwise), `--marketing-scale <n>` for stills,
/// `--marketing-video-scale <n>` and `--marketing-fps <n>` for animations, and
/// `--marketing-only <name,name>` to render a subset, and `--marketing-ffmpeg <path>` to encode the
/// animations (stills only without it). `--marketing-pointer` draws the scripted cursor into the
/// videos (off by default — the controls moving one at a time read as hand-driven on their own).
///
/// Every scene uses the real control views bound to `.constant` values — never a `PhotoAsset` —
/// and none of those values sit at a control's default: a still at defaults (flat curve, centered
/// wheel puck) reads as an empty control. Videos are scripted interaction sessions — one control
/// dragged at a time (the cursor itself drawn only with `--marketing-pointer`) — that undo their own edits so they loop
/// seamlessly; every value they pass through stays off the defaults too.
@MainActor
enum MarketingExport {
    static let flag = "--export-marketing"

    static var isRequested: Bool { CommandLine.arguments.contains(flag) }

    /// Renders everything, then terminates the process — called from `AppDelegate` before any
    /// window has done real work.
    static func runAndExit() -> Never {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        guard let outputPath = value(flag) else {
            FileHandle.standardError.write("usage: \(flag) <output dir>\n".data(using: .utf8)!)
            exit(2)
        }
        // Lay the persisted UI toggles these views read via `@AppStorage` out the way the
        // exports need them — in the volatile argument domain, so nothing is written to the
        // user's real preferences.
        UserDefaults.standard.setVolatileDomain(
            ["curveCollapsed": false, "curveEditMode": "points", "detailCloseUpVisible": true],
            forName: UserDefaults.argumentDomain
        )

        let exporter = Exporter(
            output: URL(fileURLWithPath: outputPath, isDirectory: true),
            data: MarketingData(photoPath: value("--marketing-photo")),
            stillScale: value("--marketing-scale").flatMap(Double.init) ?? 4,
            videoScale: value("--marketing-video-scale").flatMap(Double.init) ?? 2,
            fps: value("--marketing-fps").flatMap(Int.init) ?? 60,
            only: value("--marketing-only").map { Set($0.split(separator: ",").map(String.init)) },
            ffmpeg: value("--marketing-ffmpeg"),
            showsPointer: args.contains("--marketing-pointer")
        )
        do {
            try exporter.run()
            exit(0)
        } catch {
            FileHandle.standardError.write("marketing export failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

// MARK: - Data

/// Everything the data-driven controls draw behind their marks, measured once from the photo the
/// same way `EditorRenderCoordinator.updateHistograms` measures a live render.
struct MarketingData {
    /// Full-resolution crop around the photo's most detailed area — what the Detail close-up
    /// magnifies (it zooms toward 1:1, so the downsampled copy below would read as pixelated).
    let image: CGImage?
    let luminance: [Float]
    let hue: [Float]
    let rgb: RGBHistogramData
    let stats: ImageToneStats
    let waveform: CGImage?
    let vectorscope: CGImage?

    /// `closeUpCenter` is where in the frame (0...1, top-left origin) the close-up crop is taken.
    init(photoPath: String?, closeUpCenter: CGPoint = CGPoint(x: 0.63, y: 0.6)) {
        let url = photoPath.map { URL(fileURLWithPath: $0) }
        let image = url.flatMap { Self.loadDownsampled($0, maxPixel: 2400) }
        self.image = url.flatMap { Self.loadCrop($0, center: closeUpCenter, side: 1400) }
        if let image {
            luminance = Histogram.luminance(from: image)
            hue = Histogram.hue(from: image)
            rgb = Histogram.rgbChannels(from: image, bins: 128, maxSamples: 120_000)
            stats = Histogram.toneStats(from: image)
            waveform = PhotoScopes.waveform(from: image)
            vectorscope = PhotoScopes.vectorscope(from: image)
        } else {
            func bumps(_ n: Int, _ peaks: [(Float, Float, Float)]) -> [Float] {
                (0..<n).map { i in
                    let x = Float(i) / Float(n - 1)
                    return max(0.03, peaks.reduce(0) { $0 + $1.2 * exp(-pow((x - $1.0) / $1.1, 2)) })
                }
            }
            luminance = bumps(64, [(0.35, 0.16, 1), (0.78, 0.08, 0.5)])
            hue = bumps(64, [(0.12, 0.07, 1), (0.42, 0.06, 0.5), (0.68, 0.05, 0.7)])
            rgb = RGBHistogramData(
                r: bumps(128, [(0.52, 0.2, 1)]), g: bumps(128, [(0.45, 0.22, 1)]), b: bumps(128, [(0.36, 0.18, 1)])
            )
            stats = ImageToneStats(meanRed: 0.52, meanGreen: 0.46, meanBlue: 0.38)
            waveform = nil
            vectorscope = nil
        }
    }

    private static func loadCrop(_ url: URL, center: CGPoint, side: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = min(side, full.width, full.height)
        let x = min(max(Int(center.x * CGFloat(full.width)) - side / 2, 0), full.width - side)
        let y = min(max(Int(center.y * CGFloat(full.height)) - side / 2, 0), full.height - side)
        return full.cropping(to: CGRect(x: x, y: y, width: side, height: side))
    }

    private static func loadDownsampled(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Interaction scripts
//
// Each video is a scripted session with one pointer: it travels to a handle, presses, drags that
// one control (nothing else moves — a mouse can only hold one thing), releases, pauses, and moves
// on. The script ends by undoing its own edits and returning the pointer to where it started, so
// the video loops without a jump. Pointer positions are derived from each control's own layout
// math (see the `Handles` functions), resolved through anchors so they track the real view frames.

/// Named parameter values a scene's views read — e.g. `"exposure"`, `"c3"`.
typealias MarketingValues = [String: Double]

/// A point inside an anchored control, computed from that control's laid-out size.
struct HandleRef {
    let anchor: String
    let local: (CGSize) -> CGPoint
}

struct InteractionStep {
    enum Kind {
        /// Press on the handle, move the given values to their targets, release.
        case drag(changes: MarketingValues, duration: Double)
        /// Press and release; the values change on release (`fade` seconds, for crossfades).
        case click(changes: MarketingValues, fade: Double)
    }

    let kind: Kind
    /// Where the handle is for the current values (`start` = values when this step's press began —
    /// knobs need it, since their pointer moves by drag distance, not to the value's position).
    let handle: (_ values: MarketingValues, _ start: MarketingValues) -> HandleRef
    /// Names what the view should draw as hovered/dragged while this step is active (e.g.
    /// `"curve:3"` → `PointCurveEditor.presentedDragIndex = 3`).
    var tag: String? = nil
    /// Pointer wobble (points) on the axis the control ignores — a hand never drags dead straight.
    var wobble = CGVector.zero
    /// For a 2D drag stored as an (x, y) key pair: bows the path sideways by this fraction of its
    /// length, so it arcs like a hand's drag — and, for a wheel puck, around the neutral center
    /// instead of straight through it.
    var bend: (x: String, y: String, amount: Double)? = nil
    var dwell = 0.55

    static func drag(
        _ changes: MarketingValues, over duration: Double = 1.3, tag: String? = nil, wobble: CGVector = .zero,
        bend: (x: String, y: String, amount: Double)? = nil,
        dwell: Double = 0.55, at handle: @escaping (MarketingValues, MarketingValues) -> HandleRef
    ) -> InteractionStep {
        InteractionStep(kind: .drag(changes: changes, duration: duration), handle: handle, tag: tag, wobble: wobble, bend: bend, dwell: dwell)
    }

    static func click(
        _ changes: MarketingValues, dwell: Double = 1.6, at handle: @escaping (MarketingValues, MarketingValues) -> HandleRef
    ) -> InteractionStep {
        InteractionStep(kind: .click(changes: changes, fade: 0.18), handle: handle, dwell: dwell)
    }
}

struct InteractionScript {
    let initial: MarketingValues
    /// Where the pointer rests at the start and end of the loop.
    let rest: HandleRef
    let steps: [InteractionStep]
}

struct PointerState {
    var from: HandleRef
    var to: HandleRef
    /// 0…1 along the travel from `from` to `to` (1 once arrived).
    var progress: Double
    var offset = CGVector.zero
    var pressed = false
    /// Seconds since the press began, for the press ripple.
    var pressAge: Double? = nil
}

/// Everything a scene needs to draw one moment: values, plus pointer and hover/drag state.
struct InteractionFrame {
    var values: MarketingValues
    var pointer: PointerState? = nil
    var hoverTag: String? = nil
    var dragTag: String? = nil

    subscript(_ key: String) -> Double { values[key] ?? 0 }

    /// The index in `"prefix:index"` tags, when this frame hovers/drags one with `prefix`.
    func hoverIndex(_ prefix: String) -> Int? { index(in: hoverTag ?? dragTag, prefix) }
    func dragIndex(_ prefix: String) -> Int? { index(in: dragTag, prefix) }

    private func index(in tag: String?, _ prefix: String) -> Int? {
        guard let tag, tag.hasPrefix(prefix + ":") else { return nil }
        return Int(tag.dropFirst(prefix.count + 1))
    }
}

private enum Timing {
    static let lead = 0.5
    static let move = 0.6
    static let settle = 0.14
    static let press = 0.12
    static let hold = 0.12
    static let returnMove = 0.75
    static let tail = 0.5
}

/// Ease in/out with a small overshoot near the end and a settle back — how a hand lands on a value.
private func humanEase(_ u: Double) -> Double {
    let split = 0.8, peak = 1.03
    if u < split {
        let v = u / split
        return peak * v * v * (3 - 2 * v)
    }
    let v = (u - split) / (1 - split)
    return peak - (peak - 1) * v * v * (3 - 2 * v)
}

private func smooth(_ u: Double) -> Double { u * u * (3 - 2 * u) }

private func interpolate(_ a: MarketingValues, toward changes: MarketingValues, _ k: Double) -> MarketingValues {
    var result = a
    for (key, target) in changes {
        let from = a[key] ?? target
        result[key] = from + (target - from) * k
    }
    return result
}

extension InteractionScript {
    var duration: Double {
        var total = Timing.lead + Timing.returnMove + Timing.tail
        for step in steps {
            total += Timing.move + Timing.settle + step.dwell
            switch step.kind {
            case .drag(_, let duration): total += duration + Timing.hold
            case .click(_, let fade): total += Timing.press + fade
            }
        }
        return total
    }

    func frame(at time: Double) -> InteractionFrame {
        var values = initial
        var pointer = rest
        var clock = Timing.lead
        func at(_ ref: HandleRef) -> PointerState { PointerState(from: ref, to: ref, progress: 1) }

        if time < clock { return InteractionFrame(values: values, pointer: at(rest)) }
        for step in steps {
            let start = values
            let target = step.handle(values, start)
            if time < clock + Timing.move {
                let k = smooth((time - clock) / Timing.move)
                return InteractionFrame(values: values, pointer: PointerState(from: pointer, to: target, progress: k))
            }
            clock += Timing.move
            if time < clock + Timing.settle {
                return InteractionFrame(values: values, pointer: at(target), hoverTag: step.tag)
            }
            clock += Timing.settle

            switch step.kind {
            case .drag(let changes, let duration):
                if time < clock + duration {
                    let u = (time - clock) / duration
                    var current = interpolate(start, toward: changes, humanEase(u))
                    if let bend = step.bend, let tx = changes[bend.x], let ty = changes[bend.y] {
                        let sx = start[bend.x] ?? tx, sy = start[bend.y] ?? ty
                        let side = sin(min(max(humanEase(u), 0), 1) * .pi) * bend.amount
                        current[bend.x, default: 0] += -(ty - sy) * side
                        current[bend.y, default: 0] += (tx - sx) * side
                    }
                    var state = at(step.handle(current, start))
                    let wobble = sin(u * .pi) * sin(u * 2 * .pi * 1.4)
                    state.offset = CGVector(dx: step.wobble.dx * wobble, dy: step.wobble.dy * wobble)
                    state.pressed = true
                    state.pressAge = time - clock
                    return InteractionFrame(values: current, pointer: state, hoverTag: step.tag, dragTag: step.tag)
                }
                clock += duration
                values = interpolate(start, toward: changes, 1)
                if time < clock + Timing.hold {
                    var state = at(step.handle(values, start))
                    state.pressed = true
                    return InteractionFrame(values: values, pointer: state, hoverTag: step.tag, dragTag: step.tag)
                }
                clock += Timing.hold
            case .click(let changes, let fade):
                if time < clock + Timing.press {
                    var state = at(target)
                    state.pressed = true
                    state.pressAge = time - clock
                    return InteractionFrame(values: values, pointer: state, hoverTag: step.tag)
                }
                clock += Timing.press
                if time < clock + fade {
                    let current = interpolate(start, toward: changes, smooth((time - clock) / fade))
                    return InteractionFrame(values: current, pointer: at(target), hoverTag: step.tag)
                }
                clock += fade
                values = interpolate(start, toward: changes, 1)
            }

            let end = step.handle(values, start)
            if time < clock + step.dwell {
                return InteractionFrame(values: values, pointer: at(end), hoverTag: step.tag)
            }
            clock += step.dwell
            pointer = end
        }
        if time < clock + Timing.returnMove {
            let k = smooth((time - clock) / Timing.returnMove)
            return InteractionFrame(values: values, pointer: PointerState(from: pointer, to: rest, progress: k))
        }
        return InteractionFrame(values: values, pointer: at(rest))
    }
}

// MARK: - Handle geometry
//
// Mirrors each control's own layout math — keep in step with the files named.

private enum Handles {
    static func fraction(_ v: Double, _ range: ClosedRange<Double>) -> CGFloat {
        CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    /// `slider(...)` (EditorControls.swift) or any view ending in a `MinimalSlider`: the 24pt track
    /// is its bottom row, thumb at `fraction × width`.
    static func slider(_ anchor: String, _ v: Double, _ range: ClosedRange<Double>) -> HandleRef {
        HandleRef(anchor: anchor) { size in CGPoint(x: fraction(v, range) * size.width, y: size.height - 12) }
    }

    /// `ColorWheelControl`: 22pt title row + 6pt gap, then the wheel container centered.
    static func wheelCenter(_ size: CGSize, diameter: CGFloat) -> CGPoint {
        CGPoint(x: size.width / 2, y: controlSubtitleHeight + controlSubtitleSpacing + ColorWheelControl.containerSize(forDiameter: diameter) / 2)
    }

    /// The puck, from radius-fraction cartesian offsets (`px`, `py`; y down) — what the drag edits.
    static func wheelPuck(_ anchor: String, px: Double, py: Double, diameter: CGFloat) -> HandleRef {
        HandleRef(anchor: anchor) { size in
            let c = wheelCenter(size, diameter: diameter)
            return CGPoint(x: c.x + CGFloat(px) * diameter / 2, y: c.y + CGFloat(py) * diameter / 2)
        }
    }

    /// The luminance arc's thumb (±85° around the right side, radius `diameter / 2 + 16`).
    static func wheelArc(_ anchor: String, luminance: Double, range: ClosedRange<Double>, diameter: CGFloat) -> HandleRef {
        HandleRef(anchor: anchor) { size in
            let c = wheelCenter(size, diameter: diameter)
            let angle = (85 - Double(fraction(luminance, range)) * 170) * .pi / 180
            let r = diameter / 2 + 16
            return CGPoint(x: c.x + r * CGFloat(cos(angle)), y: c.y + r * CGFloat(sin(angle)))
        }
    }

    /// `WhiteBalanceFaderPair`: 48pt columns 20pt apart; title row, then the 200pt fader centered
    /// in `slotHeight`.
    static func wbFader(_ anchor: String, column: Int, _ v: Double, _ range: ClosedRange<Double>, slotHeight: CGFloat = colorFaderTrackHeight) -> HandleRef {
        HandleRef(anchor: anchor) { _ in
            let top = controlSubtitleHeight + controlSubtitleSpacing + (slotHeight - colorFaderTrackHeight) / 2
            return CGPoint(x: faderColumnWidth / 2 + CGFloat(column) * (faderColumnWidth + 20),
                           y: top + (1 - fraction(v, range)) * colorFaderTrackHeight)
        }
    }

    /// `WhiteBalancePad`: title row, then the square pad centered (x = tint, y = temperature).
    static func wbPad(_ anchor: String, temperature: Double, tint: Double, axes: WhiteBalanceAxes) -> HandleRef {
        HandleRef(anchor: anchor) { size in
            let side = colorFaderTrackHeight
            return CGPoint(x: (size.width - side) / 2 + fraction(tint, axes.tintRange) * side,
                           y: controlSubtitleHeight + controlSubtitleSpacing + (1 - fraction(temperature, axes.temperatureRange)) * side)
        }
    }

    /// A curve point in a graph that fills its anchor (`PointCurveEditor`) or its top
    /// `graphHeight` (`CurveEditorControl`).
    static func curvePoint(_ anchor: String, x: Double, y: Double, graphHeight: CGFloat? = nil) -> HandleRef {
        HandleRef(anchor: anchor) { size in
            CGPoint(x: CGFloat(x) * size.width, y: (1 - CGFloat(y)) * (graphHeight ?? size.height))
        }
    }

    /// `IntensityKnobLayout`'s three 56pt knobs in equal columns. Knobs turn by vertical drag
    /// distance (160pt per full range — `KnobDrag`), so the pointer starts on the knob and travels
    /// up/down by how far the value has moved since the press.
    static func knob(_ anchor: String, column: Int, of columns: Int = 3, value: Double, start: Double, range: ClosedRange<Double>) -> HandleRef {
        HandleRef(anchor: anchor) { size in
            let travel = (value - start) / (range.upperBound - range.lowerBound) * 160
            return CGPoint(x: size.width * (CGFloat(column) + 0.5) / CGFloat(columns), y: 28 - CGFloat(travel))
        }
    }

    /// `PhotoDataScopeSelector`: four equal columns, dot + label centered.
    static func scopeTab(_ anchor: String, _ index: Int) -> HandleRef {
        HandleRef(anchor: anchor) { size in CGPoint(x: size.width * (CGFloat(index) + 0.5) / 4 + 10, y: size.height / 2) }
    }

    /// A fixed spot within an anchor (fractions of its size) — the pointer's resting place.
    static func spot(_ anchor: String, _ fx: CGFloat, _ fy: CGFloat) -> HandleRef {
        HandleRef(anchor: anchor) { size in CGPoint(x: size.width * fx, y: size.height * fy) }
    }
}

// MARK: - Anchors and pointer

private struct HandleAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    /// `transformAnchorPreference`, not `anchorPreference` — the latter replaces whatever the
    /// subtree reported, which would erase every handle inside a view that's anchored itself.
    func handleAnchor(_ id: String) -> some View {
        transformAnchorPreference(key: HandleAnchorKey.self, value: .bounds) { $0[id] = $1 }
    }

    /// Draws the pointer over the whole scene, resolving its handle refs against the anchors.
    func pointerOverlay(_ pointer: PointerState?) -> some View {
        handleAnchor("scene")
            .overlayPreferenceValue(HandleAnchorKey.self) { anchors in
                if let pointer {
                    GeometryReader { proxy in
                        let resolve: (HandleRef) -> CGPoint = { ref in
                            guard let anchor = anchors[ref.anchor] else { return .zero }
                            let rect = proxy[anchor]
                            let p = ref.local(rect.size)
                            return CGPoint(x: rect.minX + p.x, y: rect.minY + p.y)
                        }
                        let a = resolve(pointer.from), b = resolve(pointer.to)
                        let k = CGFloat(pointer.progress)
                        // Travel along a gentle arc, not a ruler-straight line.
                        let dx = b.x - a.x, dy = b.y - a.y
                        let bow = sin(.pi * k) * 0.12
                        let p = CGPoint(x: a.x + dx * k - dy * bow + pointer.offset.dx,
                                        y: a.y + dy * k + dx * bow + pointer.offset.dy)
                        MarketingPointer(pressed: pointer.pressed, pressAge: pointer.pressAge)
                            .position(p)
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

/// The system arrow cursor (its real artwork, from `NSCursor`), hotspot on the point it's
/// positioned at, dipping slightly while the button is held, with a faint ripple on press.
private struct MarketingPointer: View {
    let pressed: Bool
    let pressAge: Double?
    private static let cursor = NSCursor.arrow

    var body: some View {
        let image = Self.cursor.image
        let hot = Self.cursor.hotSpot
        ZStack(alignment: .topLeading) {
            if let pressAge, pressAge < 0.4 {
                let k = pressAge / 0.4
                Circle()
                    .strokeBorder(Color.white.opacity(0.45 * (1 - k)), lineWidth: 1.5)
                    .frame(width: 8 + 26 * k, height: 8 + 26 * k)
                    .position(x: 0, y: 0)
            }
            Image(nsImage: image)
                .frame(width: image.size.width, height: image.size.height)
                .scaleEffect(pressed ? 0.9 : 1, anchor: UnitPoint(x: hot.x / image.size.width, y: hot.y / image.size.height))
                .offset(x: -hot.x, y: -hot.y)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
        .frame(width: 0, height: 0, alignment: .topLeading)
    }
}

// MARK: - Scenes

/// One exported subject. `script == nil` means still only; the still uses the script's initial
/// values, which — like every value a script passes through — stay off each control's default.
struct MarketingScene {
    let name: String
    /// `nil` sizes to the content's ideal width (rows of fixed-size controls).
    let width: CGFloat?
    var script: InteractionScript? = nil
    var stillValues: MarketingValues = [:]
    let view: (InteractionFrame) -> AnyView

    var initialValues: MarketingValues { script?.initial ?? stillValues }
}

private let wbAxes = WhiteBalanceAxes(defaultTemperature: 5500, defaultTint: 0)
private let barWheelDiameter = colorFaderTrackHeight - 26
private let barSlotHeight = ColorWheelControl.containerSize(forDiameter: colorFaderTrackHeight - 26)

/// Tone curve: interior point x positions (endpoints pinned at 0 and 1).
private let curveXs: [Double] = [0, 0.26, 0.55, 0.8, 1]
/// Color Zones point x positions.
private let zoneXs: [Double] = [0.08, 0.24, 0.42, 0.6, 0.8]

private let curveInitial: MarketingValues = ["c0": 0.04, "c1": 0.19, "c2": 0.6, "c3": 0.87, "c4": 0.97, "blackLift": 0.05]
private let zonesInitial: MarketingValues = ["z0": 0.6, "z1": 0.42, "z2": 0.57, "z3": 0.36, "z4": 0.62]
private let wheelsInitial: MarketingValues = [
    "w0x": 0.42, "w0y": -0.3, "w0l": 0.012,
    "w1x": -0.32, "w1y": 0.2, "w1l": -0.18,
    "w2x": 0.16, "w2y": 0.14, "w2l": 0.04,
    "w3x": 0.3, "w3y": -0.52, "w3l": 0.08,
]
private let intensityInitial: MarketingValues = ["chroma": 0.16, "vibrance": 0.22, "saturation": 12]
private let exposureInitial: MarketingValues = ["exposure": 0.58, "contrast": 0.3]
private let detailValues: MarketingValues = ["sharpness": 0.5, "dehaze": 0.36, "denoise": 0.23, "lens": 0.74]

/// Per-wheel ranges, as `ColorBalanceBarView` passes them.
private let wheelSpecs: [(title: String, maxChroma: Double, yRange: ClosedRange<Double>)] = [
    ("Global", 0.01, -0.05...0.05), ("Shadows", 0.5, -1...1), ("Midtones", 0.1, -0.25...0.25), ("Highlights", 0.2, -0.5...0.5),
]

// Reusable steps

private func curveDrag(_ index: Int, to y: Double, anchor: String = "curve", over duration: Double = 1.2) -> InteractionStep {
    .drag(["c\(index)": y], over: duration, tag: "curve:\(index)") { v, _ in
        Handles.curvePoint(anchor, x: curveXs[index], y: v["c\(index)"] ?? 0)
    }
}

private func zoneDrag(_ index: Int, to y: Double) -> InteractionStep {
    .drag(["z\(index)": y], over: 1.2, tag: "zones:\(index)") { v, _ in
        Handles.curvePoint("zones", x: zoneXs[index], y: v["z\(index)"] ?? 0, graphHeight: colorFaderTrackHeight)
    }
}

private func puckDrag(_ wheel: Int, to px: Double, _ py: Double, diameter: CGFloat, over duration: Double = 1.4, bend: Double = 0.12) -> InteractionStep {
    .drag(["w\(wheel)x": px, "w\(wheel)y": py], over: duration, bend: ("w\(wheel)x", "w\(wheel)y", bend)) { v, _ in
        Handles.wheelPuck("wheel\(wheel)", px: v["w\(wheel)x"] ?? 0, py: v["w\(wheel)y"] ?? 0, diameter: diameter)
    }
}

private func arcDrag(_ wheel: Int, to l: Double, diameter: CGFloat, range: ClosedRange<Double>) -> InteractionStep {
    .drag(["w\(wheel)l": l], over: 1.0) { v, _ in
        Handles.wheelArc("wheel\(wheel)", luminance: v["w\(wheel)l"] ?? 0, range: range, diameter: diameter)
    }
}

private func knobDrag(_ key: String, column: Int, to value: Double, range: ClosedRange<Double>) -> InteractionStep {
    .drag([key: value], over: 1.1, wobble: CGVector(dx: 1.5, dy: 0)) { v, start in
        Handles.knob("knobs", column: column, value: v[key] ?? 0, start: start[key] ?? 0, range: range)
    }
}

private func sliderDrag(_ key: String, anchor: String, to value: Double, range: ClosedRange<Double>) -> InteractionStep {
    .drag([key: value], over: 1.2, wobble: CGVector(dx: 0, dy: 1.5)) { v, _ in
        Handles.slider(anchor, v[key] ?? 0, range)
    }
}

private func faderDrag(_ key: String, column: Int, to value: Double, range: ClosedRange<Double>, slotHeight: CGFloat = colorFaderTrackHeight) -> InteractionStep {
    .drag([key: value], over: 1.2, wobble: CGVector(dx: 1.5, dy: 0)) { v, _ in
        Handles.wbFader("faders", column: column, v[key] ?? 0, range, slotHeight: slotHeight)
    }
}

@MainActor
private func scenes(_ data: MarketingData) -> [MarketingScene] {
    [
        MarketingScene(
            name: "editor-sidebar", width: 420,
            script: InteractionScript(
                initial: exposureInitial.merging(curveInitial) { $1 }.merging(intensityInitial) { $1 },
                rest: Handles.spot("scene", 0.82, 0.3),
                steps: [
                    sliderDrag("exposure", anchor: "exposure", to: 1.05, range: -4...4),
                    curveDrag(3, to: 0.94),
                    knobDrag("chroma", column: 0, to: 0.3, range: -0.5...0.5),
                    sliderDrag("exposure", anchor: "exposure", to: 0.58, range: -4...4),
                    curveDrag(3, to: 0.87),
                    knobDrag("chroma", column: 0, to: 0.16, range: -0.5...0.5),
                ]
            )
        ) { f in AnyView(SidebarReplica(data: data, f: f).panel(padding: 16)) },

        MarketingScene(
            name: "color-grading-bar", width: nil,
            script: InteractionScript(
                initial: wheelsInitial.merging(zonesInitial) { $1 }.merging(["temp": 6400, "tint": 14]) { $1 },
                rest: Handles.spot("scene", 0.5, 0.92),
                steps: [
                    faderDrag("temp", column: 0, to: 7300, range: wbAxes.temperatureRange, slotHeight: barSlotHeight),
                    puckDrag(1, to: -0.55, -0.12, diameter: barWheelDiameter),
                    zoneDrag(3, to: 0.22),
                    faderDrag("temp", column: 0, to: 6400, range: wbAxes.temperatureRange, slotHeight: barSlotHeight),
                    puckDrag(1, to: -0.32, 0.2, diameter: barWheelDiameter),
                    zoneDrag(3, to: 0.36),
                ]
            )
        ) { f in AnyView(ColorBarReplica(data: data, f: f).panel(padding: 24)) },

        MarketingScene(
            name: "color-wheels", width: nil,
            script: InteractionScript(
                initial: wheelsInitial,
                rest: Handles.spot("scene", 0.5, 0.95),
                steps: [
                    puckDrag(1, to: -0.6, -0.1, diameter: 174),
                    puckDrag(3, to: 0.52, -0.42, diameter: 174),
                    arcDrag(2, to: 0.12, diameter: 174, range: -0.25...0.25),
                    puckDrag(1, to: -0.32, 0.2, diameter: 174),
                    puckDrag(3, to: 0.3, -0.52, diameter: 174),
                    arcDrag(2, to: 0.04, diameter: 174, range: -0.25...0.25),
                ]
            )
        ) { f in AnyView(WheelRow(f: f, diameter: 174).panel(padding: 20)) },

        MarketingScene(
            name: "color-wheel", width: 320,
            script: InteractionScript(
                initial: ["w1x": -0.4, "w1y": 0.32, "w1l": 0.14],
                rest: Handles.spot("scene", 0.86, 0.9),
                steps: [
                    puckDrag(1, to: 0.46, -0.36, diameter: 220, over: 1.6, bend: 0.45),
                    arcDrag(1, to: 0.4, diameter: 220, range: -1...1),
                    puckDrag(1, to: -0.4, 0.32, diameter: 220, over: 1.6, bend: 0.45),
                    arcDrag(1, to: 0.14, diameter: 220, range: -1...1),
                ]
            )
        ) { f in
            AnyView(
                MarketingWheel(f: f, index: 1, title: "Shadows", maxChroma: 0.5, yRange: -1...1, diameter: 220)
                    .frame(maxWidth: .infinity)
                    .panel(padding: 20)
            )
        },

        MarketingScene(
            name: "tone-curve", width: 420,
            script: InteractionScript(
                initial: curveInitial,
                rest: Handles.spot("scene", 0.9, 0.95),
                steps: [curveDrag(3, to: 0.95), curveDrag(1, to: 0.11), curveDrag(3, to: 0.87), curveDrag(1, to: 0.19)]
            )
        ) { f in AnyView(CurveSectionReplica(data: data, f: f).panel(padding: 16)) },

        MarketingScene(
            name: "color-zones", width: 680,
            script: InteractionScript(
                initial: zonesInitial,
                rest: Handles.spot("scene", 0.5, 0.97),
                steps: [zoneDrag(3, to: 0.2), zoneDrag(1, to: 0.56), zoneDrag(3, to: 0.36), zoneDrag(1, to: 0.42)]
            )
        ) { f in AnyView(ColorZonesReplica(data: data, f: f).panel(padding: 24)) },

        MarketingScene(
            name: "white-balance-pad", width: 290,
            script: InteractionScript(
                initial: ["temp": 6800, "tint": 22],
                rest: Handles.spot("scene", 0.88, 0.96),
                steps: [
                    .drag(["temp": 5900, "tint": 46], over: 1.5) { v, _ in Handles.wbPad("pad", temperature: v["temp"]!, tint: v["tint"]!, axes: wbAxes) },
                    .drag(["temp": 7700, "tint": 8], over: 1.6) { v, _ in Handles.wbPad("pad", temperature: v["temp"]!, tint: v["tint"]!, axes: wbAxes) },
                    .drag(["temp": 6800, "tint": 22], over: 1.4) { v, _ in Handles.wbPad("pad", temperature: v["temp"]!, tint: v["tint"]!, axes: wbAxes) },
                ]
            )
        ) { f in
            AnyView(
                WhiteBalancePad(temperature: .constant(f["temp"]), tint: .constant(f["tint"]), axes: wbAxes)
                    .handleAnchor("pad")
                    .frame(maxWidth: .infinity)
                    .panel(padding: 24)
            )
        },

        MarketingScene(
            name: "white-balance-faders", width: 200,
            script: InteractionScript(
                initial: ["temp": 6400, "tint": 14],
                rest: Handles.spot("scene", 0.9, 0.97),
                steps: [
                    faderDrag("temp", column: 0, to: 7600, range: wbAxes.temperatureRange),
                    faderDrag("tint", column: 1, to: 34, range: wbAxes.tintRange),
                    faderDrag("temp", column: 0, to: 6400, range: wbAxes.temperatureRange),
                    faderDrag("tint", column: 1, to: 14, range: wbAxes.tintRange),
                ]
            )
        ) { f in
            AnyView(
                WhiteBalanceFaderPair(temperature: .constant(f["temp"]), tint: .constant(f["tint"]), axes: wbAxes)
                    .handleAnchor("faders")
                    .frame(maxWidth: .infinity)
                    .panel(padding: 24)
            )
        },

        MarketingScene(
            name: "photo-data", width: 420,
            script: InteractionScript(
                initial: ["scope": 0],
                rest: Handles.spot("scene", 0.8, 0.7),
                steps: (1...4).map { i in
                    .click(["scope": Double(i)]) { _, _ in Handles.scopeTab("scopes", i % 4) }
                }
            )
        ) { f in AnyView(ScopesReplica(data: data, scope: f["scope"]).panel(padding: 16)) },

        MarketingScene(name: "histogram", width: 420) { _ in AnyView(ScopesReplica(data: data, scope: 0).panel(padding: 16)) },
        MarketingScene(name: "waveform", width: 420) { _ in AnyView(ScopesReplica(data: data, scope: 1).panel(padding: 16)) },
        MarketingScene(name: "vectorscope", width: 420) { _ in AnyView(ScopesReplica(data: data, scope: 2).panel(padding: 16)) },
        MarketingScene(name: "zones", width: 420) { _ in AnyView(ScopesReplica(data: data, scope: 3).panel(padding: 16)) },

        MarketingScene(
            name: "exposure-contrast", width: 420,
            script: InteractionScript(
                initial: exposureInitial,
                rest: Handles.spot("scene", 0.5, 0.97),
                steps: [
                    sliderDrag("exposure", anchor: "exposure", to: 1.2, range: -4...4),
                    sliderDrag("contrast", anchor: "contrast", to: 0.14, range: -0.5...0.5),
                    sliderDrag("exposure", anchor: "exposure", to: 0.58, range: -4...4),
                    sliderDrag("contrast", anchor: "contrast", to: 0.3, range: -0.5...0.5),
                ]
            )
        ) { f in AnyView(ExposureContrastReplica(data: data, f: f).panel(padding: 16)) },

        MarketingScene(name: "tone-mapping", width: 420) { _ in AnyView(ToneMappingReplica().panel(padding: 16)) },

        MarketingScene(
            name: "color-intensity", width: 420,
            script: InteractionScript(
                initial: intensityInitial,
                rest: Handles.spot("scene", 0.5, 1.1),
                steps: [
                    knobDrag("chroma", column: 0, to: 0.3, range: -0.5...0.5),
                    knobDrag("saturation", column: 2, to: 30, range: -100...100),
                    knobDrag("chroma", column: 0, to: 0.16, range: -0.5...0.5),
                    knobDrag("saturation", column: 2, to: 12, range: -100...100),
                ]
            )
        ) { f in AnyView(IntensityReplica(data: data, f: f).panel(padding: 16)) },

        MarketingScene(name: "detail", width: 420, stillValues: detailValues) { f in
            AnyView(DetailReplica(data: data, f: f).panel(padding: 16))
        },
    ]
}

// MARK: - Replicas of the editor's sections
//
// These mirror the layout of `EditorSidebarView`/`ColorBalanceBarView`, whose own bodies are bound
// to a live `PhotoAsset`/`Stage`/`EditorRenderCoordinator` and can't be drawn from sample values.
// Keep them in step when those layouts change.

private struct ScopesReplica: View {
    let data: MarketingData
    /// Scope index; fractional mid-crossfade (4 wraps to 0, so the loop can end where it began).
    let scope: Double

    var body: some View {
        let all = PhotoDataPanel.Scope.allCases
        let lower = Int(scope.rounded(.down))
        let mix = scope - Double(lower)
        let current = all[lower % all.count], next = all[(lower + 1) % all.count]
        VStack(alignment: .leading, spacing: 8) {
            PhotoDataScopeSelector(scope: .constant(mix > 0.5 ? next : current))
                .handleAnchor("scopes")
            ZStack {
                scopeView(current).opacity(1 - mix)
                if mix > 0 { scopeView(next).opacity(mix) }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func scopeView(_ scope: PhotoDataPanel.Scope) -> some View {
        switch scope {
        case .histogram: RGBHistogramView(data: data.rgb, height: 240, stats: data.stats)
        case .waveform: WaveformScope(image: data.waveform, height: 240)
        case .vectorscope: VectorscopeView(image: data.vectorscope, height: 240)
        case .zones: ZoneSystemView(histogram: data.luminance, height: 240)
        }
    }
}

private struct ExposureContrastReplica: View {
    let data: MarketingData
    let f: InteractionFrame

    var body: some View {
        section(nil) {
            slider(
                "Exposure", value: .constant(f["exposure"]), range: -4...4, resetValue: 0,
                ticks: [-4, -3, -2, -1, 0, 1, 2, 3, 4], trackStyle: .hairline, thumbShape: .diamond
            )
            .handleAnchor("exposure")
            ContrastRampMapping(value: .constant(f["contrast"]), showsRamps: false, histogram: data.luminance, stats: data.stats)
                .handleAnchor("contrast")
        }
    }
}

private struct ToneMappingReplica: View {
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Tone Mapping", enabled: nil)
            HStack(spacing: 6) {
                ToneMapperCurveCarousel(selection: .constant(.agx), drawsBackground: false)
                Image(systemName: "chevron.down").font(.caption)
            }
            .padding(8)
            .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// `EditorSidebarView`'s Curve section, with `CurveWorkbench`'s points-mode layout inlined so the
/// graph can show the scripted hover/drag (the workbench keeps that state private).
private struct CurveSectionReplica: View {
    let data: MarketingData
    let f: InteractionFrame
    @Environment(ColorSchemeStore.self) private var uiColors

    private var points: [SIMD2<Double>] {
        curveXs.indices.map { SIMD2(curveXs[$0], f["c\($0)"]) }
    }

    var body: some View {
        let points = points
        let focusX = f.hoverIndex("curve").map { curveXs[$0] }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                sectionTitle("Curve", enabled: .constant(true))
                curveSwitcher
                resetButton(disabled: false, action: {})
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 18)
                Spacer(minLength: 6)
                Text("Preserve Color").font(.subheadline).foregroundStyle(.secondary).fixedSize()
                StoplightToggle(isOn: .constant(true))
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    Text("Presets").font(.caption)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .fixedSize()
                StoplightToggle(isOn: .constant(true))
            }
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    PointCurveEditor(
                        points: .constant(points), histogram: data.luminance, height: 252,
                        pointsOnlyOnHover: true, showsReadout: true, snapsToDiagonal: true, hitRadius: 20, grid: .zones,
                        readout: { x, y in "Zone \(CurveZones.numeral(ofDisplay: x)) → \(CurveZones.numeral(ofDisplay: y))" },
                        editsEndpoints: false,
                        presentedDragIndex: f.dragIndex("curve"), presentsHover: f.hoverIndex("curve") != nil
                    )
                    .handleAnchor("curve")
                    CurveEdgeHandles(points: .constant(points))
                }
                .frame(height: 252)
                CurveZoneAxisLabels()
                HStack(spacing: 8) {
                    Text(focusX == nil ? "Drag to add · ⇧ fine · double-click removes"
                         : curveFocusCaption(points: points, histogram: data.luminance, focusX: focusX, withZones: true))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    modeSwitch
                }
                CurveRampStrip(points: points).padding(.top, 4)
            }
            slider("Black Lift Precise", value: .constant(f["blackLift"]), range: 0...0.15, resetValue: 0, ticks: [0, 0.05, 0.1, 0.15])
        }
    }

    private var curveSwitcher: some View {
        HStack(spacing: 0) {
            ForEach([1, 2], id: \.self) { number in
                Text("\(number)")
                    .font(.caption2.weight(number == 1 ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(number == 1 ? Color.primary : Color.secondary)
                    .frame(width: 18, height: 16)
                    .background(number == 1 ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
                    .overlay(alignment: .bottom) {
                        Circle().fill(uiColors.accentColor).frame(width: 3, height: 3).offset(y: 3)
                    }
            }
        }
        .padding(2)
        .background(uiColors.recessedTrackBackground, in: Capsule())
    }

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            ForEach(["Drag", "Points"], id: \.self) { title in
                let isSelected = title == "Points"
                Text(title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(isSelected ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
            }
        }
        .padding(2)
        .background(uiColors.recessedTrackBackground, in: Capsule())
    }
}

private struct IntensityReplica: View {
    let data: MarketingData
    let f: InteractionFrame
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        IntensityKnobLayout(
            style: .swatchesTinted,
            bindings: ColorIntensityBindings(
                chroma: .constant(f["chroma"]), vibrance: .constant(f["vibrance"]),
                saturation: .constant(f["saturation"]), saturationDefault: 0
            ),
            vectorscope: nil, photoColor: dominantPhotoColor(data.stats), showsVisualization: false
        )
        .handleAnchor("knobs")
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DetailReplica: View {
    let data: MarketingData
    let f: InteractionFrame

    var body: some View {
        DetailStyleLayout(
            style: .closeUpHeader,
            bindings: DetailBindings(
                sharpness: .constant(f["sharpness"]), sharpnessDefault: 0.3,
                dehaze: .constant(f["dehaze"]), denoise: .constant(f["denoise"]), lens: .constant(f["lens"])
            ),
            previewImage: data.image
        )
    }
}

private struct SidebarReplica: View {
    let data: MarketingData
    let f: InteractionFrame

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ScopesReplica(data: data, scope: 0)
            ExposureContrastReplica(data: data, f: f)
            ToneMappingReplica()
            CurveSectionReplica(data: data, f: f)
            IntensityReplica(data: data, f: f).padding(.top, -6)
            DetailReplica(data: data, f: InteractionFrame(values: detailValues))
        }
    }
}

/// One Color Balance RGB wheel, its puck stored as radius-fraction offsets (`w<i>x`/`w<i>y`) so a
/// scripted drag moves it in a straight line, like a hand would.
private struct MarketingWheel: View {
    let f: InteractionFrame
    let index: Int
    let title: String
    let maxChroma: Double
    let yRange: ClosedRange<Double>
    let diameter: CGFloat

    var body: some View {
        let px = f["w\(index)x"], py = f["w\(index)y"]
        let radius = min((px * px + py * py).squareRoot(), 1)
        let hue = (90 - atan2(-py, px) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        ColorWheelControl(
            title: title, hue: .constant(hue), chroma: .constant(radius * maxChroma),
            luminance: .constant(f["w\(index)l"]), maxChroma: maxChroma, luminanceRange: yRange,
            diameter: diameter, isEnabled: .constant(true)
        )
        .handleAnchor("wheel\(index)")
    }
}

/// The four wheels as `ColorBalanceBarView` lays them out (overlapping by 10pt).
private struct WheelRow: View {
    let f: InteractionFrame
    var diameter: CGFloat = barWheelDiameter

    var body: some View {
        HStack(spacing: -10) {
            ForEach(wheelSpecs.indices, id: \.self) { i in
                MarketingWheel(f: f, index: i, title: wheelSpecs[i].title, maxChroma: wheelSpecs[i].maxChroma,
                               yRange: wheelSpecs[i].yRange, diameter: diameter)
            }
        }
    }
}

private struct ColorZonesReplica: View {
    let data: MarketingData
    let f: InteractionFrame

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                sectionTitle("Color Zones", enabled: .constant(true), font: .scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                    .fixedSize()
                Spacer(minLength: 8)
                resetButton(disabled: false, action: {}).frame(width: 18, height: 18)
                StoplightToggle(isOn: .constant(true))
            }
            .frame(height: 24)
            VStack(spacing: controlSubtitleSpacing) {
                HStack(spacing: 0) {
                    channelTab("Lightness", selected: false)
                    channelTab("Chroma", selected: true)
                    channelTab("Hue", selected: false)
                }
                .frame(height: controlSubtitleHeight)
                CurveEditorControl(
                    points: .constant(zoneXs.indices.map { SIMD2(zoneXs[$0], f["z\($0)"]) }), height: colorFaderTrackHeight,
                    identityPoints: ColorZonesParameters.identityPoints,
                    maxPoints: ColorZonesKernel.maxNodes, splineType: .catmullRom, referenceIsFlat: true,
                    histogram: data.hue,
                    showHueAxis: true, showHeader: false, lineColor: .white, showGrid: true,
                    hueStyle: .centerStripe, hueBackground: .outline,
                    presentedDragIndex: f.dragIndex("zones")
                )
                .handleAnchor("zones")
                .frame(height: barSlotHeight, alignment: .top)
            }
        }
    }

    private func channelTab(_ title: String, selected: Bool) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(selected ? Color.primary : Color.secondary)
            StoplightToggle(isOn: .constant(selected), diameter: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `ColorBalanceBarView`'s WB + Color Wheels + Color Zones row.
private struct ColorBarReplica: View {
    let data: MarketingData
    let f: InteractionFrame

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            HStack(alignment: .top, spacing: 28) {
                group("WB", accessory: true) {
                    WhiteBalanceFaderPair(
                        temperature: .constant(f["temp"]), tint: .constant(f["tint"]), axes: wbAxes, slotHeight: barSlotHeight
                    )
                    .handleAnchor("faders")
                }
                group("Color Wheels") { WheelRow(f: f) }
            }
            .fixedSize(horizontal: true, vertical: false)
            ColorZonesReplica(data: data, f: f).frame(width: 620)
        }
    }

    private func group<Content: View>(_ title: String, accessory: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .center, spacing: 8) {
            HStack(spacing: 4) {
                Color.clear.frame(width: 22, height: 22)
                if accessory { Color.clear.frame(width: 18, height: 18) }
                sectionTitle(title, enabled: .constant(true), font: .scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                StoplightToggle(isOn: .constant(true))
                if accessory {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
            }
            .frame(height: 24)
            content()
        }
    }
}

// MARK: - Framing

private extension View {
    /// The panel as it sits in the app: sidebar-colored, rounded, with a faint edge so it still
    /// reads on a near-black web page.
    func panel(padding: CGFloat) -> some View {
        modifier(MarketingPanel(padding: padding))
    }
}

private struct MarketingPanel: ViewModifier {
    let padding: CGFloat
    @Environment(ColorSchemeStore.self) private var uiColors

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(uiColors.sidebarBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

/// The panel on a soft backdrop with a drop shadow — ready to drop into a page as-is.
private struct MarketingBackdrop<Content: View>: View {
    let content: Content
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        content
            .shadow(color: .black.opacity(0.55), radius: 30, y: 14)
            .padding(56)
            .background(
                ZStack {
                    uiColors.workspaceBackground
                    RadialGradient(
                        colors: [Color.white.opacity(0.06), .clear],
                        center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 700
                    )
                }
            )
    }
}

// MARK: - Rendering

@MainActor
private struct Exporter {
    let output: URL
    let data: MarketingData
    let stillScale: Double
    let videoScale: Double
    let fps: Int
    let only: Set<String>?
    /// Animations are piped straight into ffmpeg as raw frames (MP4 + WebM in one pass) rather
    /// than written out as a PNG sequence first — a full run is several thousand 2x frames, which
    /// is many GB as PNGs. `nil` skips the videos.
    let ffmpeg: String?
    let showsPointer: Bool
    let colors = ColorSchemeStore()

    func run() throws {
        let fm = FileManager.default
        let stills = output.appendingPathComponent("stills", isDirectory: true)
        let videos = output.appendingPathComponent("videos", isDirectory: true)
        try fm.createDirectory(at: stills, withIntermediateDirectories: true)
        try fm.createDirectory(at: videos, withIntermediateDirectories: true)

        for scene in scenes(data) where only?.contains(scene.name) ?? true {
            log("still  \(scene.name)")
            let still = InteractionFrame(values: scene.initialValues)
            try write(render(scene, still, scale: stillScale, framed: false), to: stills.appendingPathComponent("\(scene.name).png"))
            try write(render(scene, still, scale: stillScale, framed: true), to: stills.appendingPathComponent("\(scene.name)-framed.png"))

            guard let script = scene.script, let ffmpeg else { continue }
            let count = Int((script.duration * Double(fps)).rounded())
            log("video  \(scene.name) \(String(format: "%.1f", script.duration))s ×\(count)")
            try encodeVideo(scene, script: script, frameCount: count, ffmpeg: ffmpeg, to: videos)
        }
    }

    private func encodeVideo(_ scene: MarketingScene, script: InteractionScript, frameCount: Int, ffmpeg: String, to videos: URL) throws {
        // The poster is the opening state without a pointer — the same frame the still shows.
        let first = try render(scene, InteractionFrame(values: script.initial), scale: videoScale, framed: true)
        try write(first, to: videos.appendingPathComponent("\(scene.name)-poster.png"))
        // Every frame is drawn onto one fixed, even-sized canvas (yuv420p needs even dimensions),
        // centered — a value pill's text width can nudge a frame's natural size by a pixel.
        let width = first.width & ~1, height = first.height & ~1
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { throw ExportError.renderFailed }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        let base = videos.appendingPathComponent(scene.name).path
        process.arguments = [
            "-loglevel", "error", "-y",
            "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)", "-r", "\(fps)", "-i", "-",
            "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p", "-movflags", "+faststart", base + ".mp4",
            "-c:v", "libvpx-vp9", "-crf", "28", "-b:v", "0", "-row-mt", "1", "-pix_fmt", "yuv420p", base + ".webm",
        ]
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()

        for index in 0..<frameCount {
            try autoreleasepool {
                let frame = script.frame(at: Double(index) / Double(fps))
                let image = try render(scene, frame, scale: videoScale, framed: true)
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(image, in: CGRect(
                    x: (width - image.width) / 2, y: (height - image.height) / 2, width: image.width, height: image.height
                ))
                guard let bytes = context.data else { throw ExportError.renderFailed }
                try pipe.fileHandleForWriting.write(contentsOf: Data(bytes: bytes, count: width * height * 4))
            }
        }
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExportError.encodeFailed(scene.name) }
    }

    private func render(_ scene: MarketingScene, _ frame: InteractionFrame, scale: Double, framed: Bool) throws -> CGImage {
        let view = scene.view(frame)
        let sized = Group {
            if let width = scene.width { view.frame(width: width) } else { view.fixedSize() }
        }
        .pointerOverlay(showsPointer ? frame.pointer : nil)
        let root = Group {
            if framed { AnyView(MarketingBackdrop(content: sized)) } else { AnyView(sized) }
        }
        .environment(colors)
        .environment(\.colorScheme, .dark)
        .tint(colors.accentColor)

        let renderer = ImageRenderer(content: root)
        renderer.scale = scale
        renderer.isOpaque = framed
        guard let image = renderer.cgImage else { throw ExportError.renderFailed }
        return image
    }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.writeFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.writeFailed(url) }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("[marketing] \(message)\n".data(using: .utf8)!)
    }

    enum ExportError: Error {
        case renderFailed
        case writeFailed(URL)
        case encodeFailed(String)
    }
}
