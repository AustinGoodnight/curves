import SwiftUI
import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import PhotoCatalog

/// Replaces the plain preview `Image` in `EditorView`'s image pane while `EditorView
/// .maskEditingStage` is set. Paint a rough mask with the brush, then "Refine" runs
/// `GuidedMaskRefiner` to snap the rough boundary to the photo's own edges — "Done" rasterizes
/// the working mask into `stage.maskData`.
struct AssistedMaskEditorOverlay: View {
    let stage: Stage
    let previewImage: CGImage
    /// Called once, on both Done and Cancel — the caller can't tell which happened from this
    /// alone, but doesn't need to: Done already wrote `stage.maskData` before calling it, Cancel
    /// never touched it.
    var onFinished: () -> Void

    @State private var brushRadius: CGFloat = 28
    /// Drives `GuidedMaskRefiner.refine(epsilon:)` on a log scale (`epsilon = 10^(-1 - 3 ×
    /// sensitivity)`, ranging 1e-1 at 0 to 1e-4 at 1) — a linear slider over epsilon itself would
    /// spend nearly all its range on values that look identical, since the right value depends
    /// heavily on this photo's own contrast/texture. 1.0 (max sensitivity) snaps to any edge,
    /// however faint; 0.0 treats more of the photo's texture as noise and smooths more broadly.
    /// 0.57 ≈ `GuidedMaskRefiner.refine`'s own default epsilon (2e-3).
    @State private var refineSensitivity: Double = 0.57
    @State private var canvas: MaskCanvas?
    @State private var displayedMask: CGImage?
    /// `displayedMask` converted to carry real alpha (via `CIMaskToAlpha`), kept alongside it
    /// rather than recomputed in `body` — SwiftUI's `.mask()` reads a mask view's *alpha* channel,
    /// and the plain grayscale `displayedMask` has none (opaque throughout), so used directly it
    /// would mask nothing. Updated together with `displayedMask` by `updateDisplayedMask(_:)`.
    @State private var displayedMaskAlpha: CGImage?
    @State private var isRefining = false
    @State private var errorMessage: String?
    @State private var displayContext = CIContext()
    /// Cursor position in view space, for the brush-size guide circle — updated by hover *and* by
    /// drags (painting and command-resize both move the cursor too), cleared when the cursor
    /// leaves the image entirely so the guide doesn't linger over the toolbar.
    @State private var cursorLocation: CGPoint?
    /// Set at the start of a command-held drag (`resizeAnchor.radius`/`.location`) so the whole
    /// drag's vertical delta maps to a size change relative to where it began, not to the previous
    /// event — matters because event deltas alone would compound rounding across a long drag.
    @State private var resizeAnchor: (radius: CGFloat, location: CGPoint)?
    private static let brushRadiusRange: ClosedRange<CGFloat> = 6...80

    private var imageSize: CGSize {
        CGSize(width: previewImage.width, height: previewImage.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let fitRect = Self.aspectFitRect(imageSize: imageSize, in: geometry.size)
                ZStack {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                    if let displayedMaskAlpha {
                        Color.cyan.opacity(0.5)
                            .mask(
                                Image(decorative: displayedMaskAlpha, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            )
                            .allowsHitTesting(false)
                    }
                    if let cursorLocation, fitRect.contains(cursorLocation) {
                        // Brush radius is in image-pixel space; scale by the fit's own zoom
                        // factor (not `geometry.size` directly) so the guide's on-screen size
                        // tracks the actual painted radius regardless of how far the image is
                        // letterboxed down from its native resolution.
                        let viewRadius = brushRadius * fitRect.width / imageSize.width
                        Circle()
                            .stroke(Color.white, lineWidth: 1.5)
                            .background(Circle().stroke(Color.black.opacity(0.6), lineWidth: 3).padding(-1))
                            .frame(width: viewRadius * 2, height: viewRadius * 2)
                            .position(cursorLocation)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): cursorLocation = location
                    case .ended: cursorLocation = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            cursorLocation = value.location
                            if NSEvent.modifierFlags.contains(.command) {
                                let anchor = resizeAnchor ?? (radius: brushRadius, location: value.location)
                                resizeAnchor = anchor
                                let delta = anchor.location.y - value.location.y
                                brushRadius = min(
                                    Self.brushRadiusRange.upperBound,
                                    max(Self.brushRadiusRange.lowerBound, anchor.radius + delta)
                                )
                                return
                            }
                            resizeAnchor = nil
                            guard let imagePoint = Self.imagePoint(from: value.location, fitRect: fitRect, imageSize: imageSize) else { return }
                            paintBrush(at: imagePoint, subtracting: NSEvent.modifierFlags.contains(.option))
                        }
                        .onEnded { _ in resizeAnchor = nil }
                )
            }
            .padding()

            toolbar
        }
        .task(id: stage.id) {
            let newCanvas = MaskCanvas(size: imageSize)
            if let existingData = stage.maskData, let existingImage = CGImage.decodePNG(existingData) {
                newCanvas.setContents(existingImage)
            }
            canvas = newCanvas
            updateDisplayedMask(newCanvas.cgImage())
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Brush · Option-drag to erase · ⌘-drag to resize")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $brushRadius, in: Self.brushRadiusRange) { Text("Brush Size") }
                .frame(width: 140)
            Text("Edge Sensitivity")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $refineSensitivity, in: 0...1) { Text("Edge Sensitivity") }
                .frame(width: 140)
            if isRefining {
                ProgressView()
                    .controlSize(.small)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Refine") { refine() }
                .disabled(displayedMask == nil || isRefining)
            Button("Cancel") { onFinished() }
            Button("Done") { finish() }
                .buttonStyle(.borderedProminent)
                .disabled(displayedMask == nil)
        }
        .padding(10)
        .background(.thinMaterial)
    }

    // MARK: - Interaction

    private func paintBrush(at imagePoint: CGPoint, subtracting: Bool) {
        canvas?.paintCircle(center: imagePoint, radius: brushRadius, erase: subtracting)
        updateDisplayedMask(canvas?.cgImage())
    }

    private func refine() {
        guard let mask = displayedMask else { return }
        let epsilon = pow(10, -1 - 3 * refineSensitivity)
        isRefining = true
        Task {
            defer { isRefining = false }
            do {
                let refined = try GuidedMaskRefiner.refine(mask: mask, guideImage: previewImage, epsilon: epsilon)
                canvas?.setContents(refined)
                updateDisplayedMask(canvas?.cgImage())
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't refine the mask."
            }
        }
    }

    private func finish() {
        defer { onFinished() }
        guard let displayedMask, let data = Self.pngData(from: displayedMask) else { return }
        stage.maskData = data
    }

    /// Core Image's `.mask()`-fed alpha conversion is the whole reason this exists as a helper
    /// rather than an inline assignment — see `displayedMaskAlpha`'s doc comment.
    private func updateDisplayedMask(_ mask: CGImage?) {
        displayedMask = mask
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

    private static func imagePoint(from viewPoint: CGPoint, fitRect: CGRect, imageSize: CGSize) -> CGPoint? {
        guard fitRect.width > 0, fitRect.height > 0, fitRect.insetBy(dx: -1, dy: -1).contains(viewPoint) else { return nil }
        let relX = (viewPoint.x - fitRect.minX) / fitRect.width
        let relY = (viewPoint.y - fitRect.minY) / fitRect.height
        return CGPoint(x: min(max(relX, 0), 1) * imageSize.width, y: min(max(relY, 0), 1) * imageSize.height)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private extension CGImage {
    static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// A simple 8-bit grayscale canvas for interactively painting a mask (white = included, black =
/// excluded). Backed by one persistent `CGContext`, flipped once at creation so its Y axis
/// matches the y-down "image pixel space" convention used elsewhere in this file (`imagePoint`) —
/// vector drawing (`paintCircle`'s `fillEllipse`) respects that flip correctly on its own.
/// `context.draw(_:in:)`, used by `setContents(_:)`, does not — Core Graphics draws an *image*
/// (as opposed to a path) into a flipped CTM upside down, confirmed empirically after a refined
/// mask kept reappearing at the wrong vertical position in the canvas — so `setContents(_:)`
/// applies its own second, compensating flip around just that one draw call.
final class MaskCanvas {
    let width: Int
    let height: Int
    private let context: CGContext

    init(size: CGSize) {
        width = max(1, Int(size.width.rounded()))
        height = max(1, Int(size.height.rounded()))
        context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
    }

    /// Overwrites the entire canvas with `image` (scaled to fill it if its size differs) — used
    /// both to seed the canvas from an existing `stage.maskData` (reopening "Refine Mask…") and
    /// to apply a freshly refined result back onto it.
    func setContents(_ image: CGImage) {
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }

    func paintCircle(center: CGPoint, radius: CGFloat, erase: Bool) {
        context.setFillColor(gray: erase ? 0 : 1, alpha: 1)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    func cgImage() -> CGImage? {
        context.makeImage()
    }
}
