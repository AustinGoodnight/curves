import SwiftUI
import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import PhotoCatalog

/// Replaces the plain preview `Image` in `EditorView`'s image pane while `EditorView
/// .gradientEditingStage` is set — the drag-handle counterpart to `AssistedMaskEditorOverlay`'s
/// brush, for `.linearGradientMask` (an edge-to-edge graduated filter, e.g. a graduated ND) and
/// `.radialGradientMask` (a circular/elliptical spot filter) stages. Drag the handle(s) to
/// reposition the gradient, then "Done" bakes it into `stage.maskData` (identically to how
/// `AssistedMaskEditorOverlay.finish()` does) and also writes the gradient's own geometry onto
/// `stage.gradientStartX`/etc. so reopening this view via "Adjust Gradient…" restores the exact
/// handle positions instead of starting over — see those fields' doc comment on `Stage`.
struct GradientMaskEditorOverlay: View {
    let stage: Stage
    let previewImage: CGImage
    /// Called once, on both Done and Cancel — Done already wrote `stage.maskData`/the gradient
    /// fields before calling it, Cancel never touched either.
    var onFinished: () -> Void

    @Environment(ColorSchemeStore.self) private var uiColors

    /// Linear: the "full effect" handle. Radial: the circle's center. Normalized 0–1 image-space
    /// coordinates, matching `Stage.gradientStartX`/`Y`'s own normalization.
    @State private var startPoint = CGPoint(x: 0.5, y: 0.5)
    /// Linear only: the "no effect" handle.
    @State private var endPoint = CGPoint(x: 0.5, y: 0.5)
    /// Radial only: normalized radius (fraction of image width) of full effect.
    @State private var radius: CGFloat = 0.25
    /// Radial only: normalized width of the soft falloff band beyond `radius`.
    @State private var feather: CGFloat = 0.15
    @State private var inverted = false

    @State private var displayedMaskAlpha: CGImage?
    @State private var displayContext = CIContext()
    /// Which handle a drag starting near it should move — resolved once at `onChanged`'s first
    /// call (nearest handle to `value.startLocation`, matching `AssistedMaskEditorOverlay
    /// .resizeAnchor`'s "decide once per gesture" pattern) and reused for the rest of that drag.
    @State private var activeHandle: Handle?

    private enum Handle { case start, end, radiusEdge }

    private static let handleHitRadius: CGFloat = 24
    /// Pinch-to-zoom + scroll-to-pan while dragging handles — see `ZoomPanState`'s doc comment.
    @State private var zoomPan = ZoomPanState()

    private var imageSize: CGSize {
        CGSize(width: previewImage.width, height: previewImage.height)
    }

    var body: some View {
        GeometryReader { geometry in
                let baseFitRect = Self.aspectFitRect(imageSize: imageSize, in: geometry.size)
                let fitRect = zoomPan.apply(to: baseFitRect)
                ZStack {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .frame(width: fitRect.width, height: fitRect.height)
                        .position(x: fitRect.midX, y: fitRect.midY)
                    if let displayedMaskAlpha {
                        Color.cyan.opacity(0.5)
                            .mask(
                                Image(decorative: displayedMaskAlpha, scale: 1)
                                    .resizable()
                                    .frame(width: fitRect.width, height: fitRect.height)
                                    .position(x: fitRect.midX, y: fitRect.midY)
                            )
                            .allowsHitTesting(false)
                    }
                    handleOverlay(fitRect: fitRect)
                    ScrollWheelCatcher { delta in zoomPan.pan(by: delta) }
                    MagnifyCatcher { delta, location in zoomPan.magnify(by: delta, anchor: location, baseFitRect: baseFitRect) }
                    zoomPan.percentPill(containerSize: geometry.size)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let handle = activeHandle ?? Self.nearestHandle(
                                to: value.startLocation, kind: stage.kind, startPoint: startPoint, endPoint: endPoint,
                                radius: radius, fitRect: fitRect, imageSize: imageSize
                            )
                            activeHandle = handle
                            guard let handle, let imagePoint = Self.imagePointNormalized(
                                from: value.location, fitRect: fitRect, imageSize: imageSize
                            ) else { return }
                            switch handle {
                            case .start: startPoint = imagePoint
                            case .end: endPoint = imagePoint
                            case .radiusEdge:
                                let dx = (imagePoint.x - startPoint.x) * imageSize.width
                                let dy = (imagePoint.y - startPoint.y) * imageSize.height
                                radius = max(0.01, hypot(dx, dy) / imageSize.width)
                            }
                            updateMask()
                        }
                        .onEnded { _ in activeHandle = nil }
                )
            }
            .padding()
        .overlay(alignment: .bottom) { toolbar }
        .task(id: stage.id) {
            loadGeometry()
            updateMask()
        }
    }

    @ViewBuilder
    private func handleOverlay(fitRect: CGRect) -> some View {
        let startView = Self.viewPoint(for: startPoint, fitRect: fitRect)
        switch stage.kind {
        case .linearGradientMask:
            let endView = Self.viewPoint(for: endPoint, fitRect: fitRect)
            Path { path in
                path.move(to: startView)
                path.addLine(to: endView)
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .allowsHitTesting(false)
            handleDot(at: startView, filled: true)
            handleDot(at: endView, filled: false)
        case .radialGradientMask:
            let edgeView = CGPoint(x: startView.x + radius * fitRect.width, y: startView.y)
            Circle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: radius * fitRect.width * 2, height: radius * fitRect.width * 2)
                .position(startView)
                .allowsHitTesting(false)
            Circle()
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: (radius + feather) * fitRect.width * 2, height: (radius + feather) * fitRect.width * 2)
                .position(startView)
                .allowsHitTesting(false)
            handleDot(at: startView, filled: true)
            handleDot(at: edgeView, filled: false)
        default:
            EmptyView()
        }
    }

    private func handleDot(at point: CGPoint, filled: Bool) -> some View {
        Circle()
            .fill(filled ? Color.white : Color.black)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .position(point)
            .allowsHitTesting(false)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(stage.kind == .linearGradientMask
                ? "Drag the white handle (full effect) and black handle (no effect) to reposition"
                : "Drag the center to move · drag the outer handle to resize")
                .font(.caption)
                .foregroundStyle(.secondary)
            if stage.kind == .radialGradientMask {
                Text("Feather")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MinimalSlider(value: Binding(
                    get: { Double(feather) },
                    set: { feather = CGFloat($0); updateMask() }
                ), range: 0.01...0.5)
                    .frame(width: 100)
            }
            Button("Invert") { inverted.toggle(); updateMask() }
                .buttonStyle(.plain)
                .foregroundStyle(inverted ? uiColors.accentColor : .primary)
            Divider().frame(height: 16)
            Button("Cancel") { onFinished() }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            Button("Done") { finish() }
                .buttonStyle(.plain)
                .foregroundStyle(uiColors.accentColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 10)
    }

    // MARK: - Geometry loading / saving

    private func loadGeometry() {
        if let sx = stage.gradientStartX, let sy = stage.gradientStartY {
            startPoint = CGPoint(x: sx, y: sy)
        } else {
            startPoint = stage.kind == .radialGradientMask ? CGPoint(x: 0.5, y: 0.5) : CGPoint(x: 0.5, y: 0.12)
        }
        switch stage.kind {
        case .linearGradientMask:
            if let ex = stage.gradientEndX, let ey = stage.gradientEndY {
                endPoint = CGPoint(x: ex, y: ey)
            } else {
                endPoint = CGPoint(x: 0.5, y: 0.55)
            }
        case .radialGradientMask:
            radius = stage.gradientRadius ?? 0.25
            feather = stage.gradientFeather ?? 0.15
        default:
            break
        }
        inverted = stage.gradientInverted ?? false
    }

    private func finish() {
        defer { onFinished() }
        guard let mask = bakeMaskImage(), let data = Self.pngData(from: mask) else { return }
        stage.maskData = data
        stage.gradientStartX = startPoint.x
        stage.gradientStartY = startPoint.y
        switch stage.kind {
        case .linearGradientMask:
            stage.gradientEndX = endPoint.x
            stage.gradientEndY = endPoint.y
            stage.gradientRadius = nil
            stage.gradientFeather = nil
        case .radialGradientMask:
            stage.gradientEndX = nil
            stage.gradientEndY = nil
            stage.gradientRadius = radius
            stage.gradientFeather = feather
        default:
            break
        }
        stage.gradientInverted = inverted
    }

    // MARK: - Live preview

    private func updateMask() {
        let mask = bakeMaskImage()
        guard let mask else {
            displayedMaskAlpha = nil
            return
        }
        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = CIImage(cgImage: mask)
        displayedMaskAlpha = toAlpha.outputImage.flatMap {
            displayContext.createCGImage($0, from: $0.extent)
        }
    }

    /// Renders the current geometry into an 8-bit grayscale, no-alpha `CGImage` at `imageSize` —
    /// the same format `MaskCanvas.cgImage()` produces, so `RawImageRenderer.applyMask` (which just
    /// decodes whatever's in `maskData` as a `CIImage` and blends by grayscale value) needs no
    /// changes to consume it.
    private func bakeMaskImage() -> CGImage? {
        let canvas = GradientMaskCanvas(size: imageSize)
        switch stage.kind {
        case .linearGradientMask:
            let start = CGPoint(x: startPoint.x * imageSize.width, y: startPoint.y * imageSize.height)
            let end = CGPoint(x: endPoint.x * imageSize.width, y: endPoint.y * imageSize.height)
            canvas.drawLinearGradient(start: start, end: end, inverted: inverted)
        case .radialGradientMask:
            let center = CGPoint(x: startPoint.x * imageSize.width, y: startPoint.y * imageSize.height)
            let pixelRadius = max(radius, 0.001) * imageSize.width
            let pixelFeather = max(feather, 0.001) * imageSize.width
            canvas.drawRadialGradient(center: center, radius: pixelRadius, feather: pixelFeather, inverted: inverted)
        default:
            return nil
        }
        return canvas.cgImage()
    }

    // MARK: - Coordinate mapping

    private static func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (containerSize.width - fittedSize.width) / 2, y: (containerSize.height - fittedSize.height) / 2)
        return CGRect(origin: origin, size: fittedSize)
    }

    /// View-space point → normalized (0–1) image-space point, clamped to the image's bounds so a
    /// handle dragged past the image's edge still lands exactly on that edge rather than losing
    /// tracking.
    private static func imagePointNormalized(from viewPoint: CGPoint, fitRect: CGRect, imageSize: CGSize) -> CGPoint? {
        guard fitRect.width > 0, fitRect.height > 0 else { return nil }
        let relX = (viewPoint.x - fitRect.minX) / fitRect.width
        let relY = (viewPoint.y - fitRect.minY) / fitRect.height
        return CGPoint(x: min(max(relX, 0), 1), y: min(max(relY, 0), 1))
    }

    private static func viewPoint(for normalized: CGPoint, fitRect: CGRect) -> CGPoint {
        CGPoint(x: fitRect.minX + normalized.x * fitRect.width, y: fitRect.minY + normalized.y * fitRect.height)
    }

    /// Which handle (if any, within `handleHitRadius` points) a drag starting at `location` should
    /// move — resolved once per gesture rather than by attaching a separate `.gesture` to each tiny
    /// handle view, so a drag that starts a few points off a handle still picks it up reliably.
    private static func nearestHandle(
        to location: CGPoint, kind: StageKind, startPoint: CGPoint, endPoint: CGPoint, radius: CGFloat,
        fitRect: CGRect, imageSize: CGSize
    ) -> Handle? {
        let startView = viewPoint(for: startPoint, fitRect: fitRect)
        switch kind {
        case .linearGradientMask:
            let endView = viewPoint(for: endPoint, fitRect: fitRect)
            let distStart = hypot(location.x - startView.x, location.y - startView.y)
            let distEnd = hypot(location.x - endView.x, location.y - endView.y)
            if distStart <= handleHitRadius && distStart <= distEnd { return .start }
            if distEnd <= handleHitRadius { return .end }
            return nil
        case .radialGradientMask:
            let edgeView = CGPoint(x: startView.x + radius * fitRect.width, y: startView.y)
            let distStart = hypot(location.x - startView.x, location.y - startView.y)
            let distEdge = hypot(location.x - edgeView.x, location.y - edgeView.y)
            if distStart <= handleHitRadius && distStart <= distEdge { return .start }
            if distEdge <= handleHitRadius { return .radiusEdge }
            return nil
        default:
            return nil
        }
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// An 8-bit grayscale, no-alpha canvas (same pixel format as `AssistedMaskEditorOverlay
/// .MaskCanvas`) that draws a full-canvas linear or radial `CGGradient` instead of brush strokes —
/// fully recomputed from scratch on every geometry change rather than painted into incrementally,
/// since a gradient (unlike brush strokes) has no history to preserve, only current parameters.
/// Flipped once at creation for the same reason `MaskCanvas` is: so gradient start/end/center points
/// given in y-down image-pixel space (matching `GradientMaskEditorOverlay`'s own coordinate
/// mapping) land in the right place without every draw call needing its own flip math.
private final class GradientMaskCanvas {
    let width: Int
    let height: Int
    private let context: CGContext
    private let colorSpace = CGColorSpaceCreateDeviceGray()

    init(size: CGSize) {
        width = max(1, Int(size.width.rounded()))
        height = max(1, Int(size.height.rounded()))
        context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
    }

    /// `components` is (gray, alpha) pairs per stop — `CGGradient`'s `colorComponents:` initializer
    /// expects `colorSpace.numberOfComponents + 1` values per stop, which for `DeviceGray` (1
    /// component) is 2: gray then alpha.
    func drawLinearGradient(start: CGPoint, end: CGPoint, inverted: Bool) {
        let components: [CGFloat] = inverted ? [0, 1, 1, 1] : [1, 1, 0, 1]
        guard let gradient = CGGradient(colorSpace: colorSpace, colorComponents: components, locations: [0, 1], count: 2) else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Three stops: solid "on" from the center out to `radius`, feathering to solid "off" by
    /// `radius + feather`, with `.drawsAfterEndLocation` extending that "off" color to fill the
    /// rest of the canvas beyond the feather band.
    func drawRadialGradient(center: CGPoint, radius: CGFloat, feather: CGFloat, inverted: Bool) {
        let boundary = radius / (radius + feather)
        let locations: [CGFloat] = [0, boundary, 1]
        let components: [CGFloat] = inverted ? [0, 1, 0, 1, 1, 1] : [1, 1, 1, 1, 0, 1]
        guard let gradient = CGGradient(colorSpace: colorSpace, colorComponents: components, locations: locations, count: 3) else { return }
        context.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius + feather,
            options: [.drawsAfterEndLocation]
        )
    }

    func cgImage() -> CGImage? {
        context.makeImage()
    }
}
