import SwiftUI
import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import PhotoCatalog

/// Replaces the plain preview `Image` in `EditorView`'s image pane while `EditorView
/// .colorRangeEditingStage` is set — click anywhere on the photo to sample a target color, then
/// Threshold/Feather select every pixel within that color distance of it. "Done" bakes the
/// selection into `stage.maskData` (identically to `GradientMaskEditorOverlay.finish()`) and keeps
/// the sampled color/threshold/feather on `colorRangeRed`/etc. so reopening ("Adjust Color
/// Range…") restores exactly what was picked instead of starting over.
struct ColorRangeMaskEditorOverlay: View {
    let stage: Stage
    let previewImage: CGImage
    /// Called once, on both Done and Cancel — Done already wrote `stage.maskData`/the color-range
    /// fields before calling it, Cancel never touched either.
    var onFinished: () -> Void

    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var targetColor = SIMD3<Double>(0.5, 0.5, 0.5)
    /// Whether the user has clicked the image at least once yet this session — before that there's
    /// no sampled color to build a mask from, so the preview stays blank rather than showing a
    /// meaningless mask built from the placeholder gray default above.
    @State private var hasSampled = false
    @State private var threshold: CGFloat = 0.15
    @State private var feather: CGFloat = 0.1
    @State private var inverted = false

    @State private var displayedMaskAlpha: CGImage?
    @State private var displayContext = CIContext()

    private var imageSize: CGSize {
        CGSize(width: previewImage.width, height: previewImage.height)
    }

    /// Pinch-to-zoom + scroll-to-pan while sampling a color — see `ZoomPanState`'s doc comment.
    @State private var zoomPan = ZoomPanState()

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
                    ScrollWheelCatcher { delta in zoomPan.pan(by: delta) }
                    MagnifyCatcher { delta, location in zoomPan.magnify(by: delta, anchor: location, baseFitRect: baseFitRect) }
                    zoomPan.percentPill(containerSize: geometry.size)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    // `DragGesture(minimumDistance: 0)`, not `.onTapGesture`, matching
                    // `AssistedMaskEditorOverlay`/`GradientMaskEditorOverlay` — plain SwiftUI tap
                    // gestures never expose a location, and a zero-minimum-distance drag's
                    // `.onEnded` still fires exactly once per click.
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            guard let imagePoint = Self.imagePoint(from: value.location, fitRect: fitRect, imageSize: imageSize),
                                  let sampled = ColorRangeMaskGenerator.sampleColor(from: previewImage, at: imagePoint) else { return }
                            targetColor = sampled
                            hasSampled = true
                            updateMask()
                        }
                )
            }
            .padding()
        .overlay(alignment: .bottom) { toolbar }
        .task(id: stage.id) {
            loadGeometry()
            updateMask()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Click the photo to sample a color")
                .font(.caption)
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: targetColor.x, green: targetColor.y, blue: targetColor.z))
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.6), lineWidth: 1))
            Text("Threshold")
                .font(.caption)
                .foregroundStyle(.secondary)
            MinimalSlider(value: Binding(get: { Double(threshold) }, set: { threshold = CGFloat($0); updateMask() }), range: 0.01...1)
                .frame(width: 100)
            Text("Feather")
                .font(.caption)
                .foregroundStyle(.secondary)
            MinimalSlider(value: Binding(get: { Double(feather) }, set: { feather = CGFloat($0); updateMask() }), range: 0.01...1)
                .frame(width: 100)
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
                .disabled(!hasSampled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 10)
    }

    // MARK: - Geometry loading / saving

    private func loadGeometry() {
        if let r = stage.colorRangeRed, let g = stage.colorRangeGreen, let b = stage.colorRangeBlue {
            targetColor = SIMD3(r, g, b)
            hasSampled = true
        }
        threshold = stage.colorRangeThreshold ?? 0.15
        feather = stage.colorRangeFeather ?? 0.1
        inverted = stage.colorRangeInverted ?? false
    }

    private func finish() {
        defer { onFinished() }
        guard hasSampled, let mask = ColorRangeMaskGenerator.makeMask(
            image: previewImage, targetColor: targetColor, threshold: threshold, feather: feather, inverted: inverted
        ), let data = Self.pngData(from: mask) else { return }
        stage.maskData = data
        stage.colorRangeRed = targetColor.x
        stage.colorRangeGreen = targetColor.y
        stage.colorRangeBlue = targetColor.z
        stage.colorRangeThreshold = threshold
        stage.colorRangeFeather = feather
        stage.colorRangeInverted = inverted
    }

    // MARK: - Live preview

    private func updateMask() {
        guard hasSampled, let mask = ColorRangeMaskGenerator.makeMask(
            image: previewImage, targetColor: targetColor, threshold: threshold, feather: feather, inverted: inverted
        ) else {
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
        guard fitRect.width > 0, fitRect.height > 0, fitRect.contains(viewPoint) else { return nil }
        let relX = (viewPoint.x - fitRect.minX) / fitRect.width
        let relY = (viewPoint.y - fitRect.minY) / fitRect.height
        return CGPoint(x: relX * imageSize.width, y: relY * imageSize.height)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Builds a color-range selection mask entirely from stock Core Image filters — same "no custom
/// kernel language" convention as `GuidedMaskRefiner`, since this runs only as a one-shot bake in
/// the editor overlay above, not on `RawImageRenderer`'s per-render stage path.
enum ColorRangeMaskGenerator {
    /// Reads the pixel at `imagePoint` (already in `image`'s own pixel space, y-down, matching
    /// `CGImage.cropping(to:)`'s own coordinate convention). Crops to exactly that one pixel first
    /// rather than drawing the full image into a 1×1 context — a single pixel has no orientation to
    /// get wrong, sidestepping the y-flip bookkeeping `MaskCanvas`/`GradientMaskCanvas` need for
    /// full-image drawing (see `MaskCanvas.setContents`'s doc comment for how easy that is to get
    /// backwards).
    static func sampleColor(from image: CGImage, at imagePoint: CGPoint) -> SIMD3<Double>? {
        let x = Int(imagePoint.x.rounded(.down))
        let y = Int(imagePoint.y.rounded(.down))
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let pixelImage = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return SIMD3(Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    /// Renders an 8-bit grayscale, no-alpha mask (same format `MaskCanvas`/`GradientMaskCanvas`
    /// produce) selecting every pixel of `image` within `threshold` Euclidean RGB distance of
    /// `targetColor`, softened by a `feather`-wide falloff band beyond it. All in Core Image's plain
    /// (color-management-disabled) working space, same reasoning as `GuidedMaskRefiner`'s context —
    /// this is raw component arithmetic on the same non-linear component values `sampleColor` reads
    /// the target from, not a color-managed operation.
    static func makeMask(image: CGImage, targetColor: SIMD3<Double>, threshold: CGFloat, feather: CGFloat, inverted: Bool) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard extent.width > 0, extent.height > 0 else { return nil }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let source = CIImage(cgImage: image)

        // diff = source - targetColor, via CIColorMatrix's bias (an identity matrix on R/G/B/A
        // plus a per-channel constant is exactly a per-component subtraction).
        let diffFilter = CIFilter.colorMatrix()
        diffFilter.inputImage = source
        diffFilter.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        diffFilter.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        diffFilter.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        diffFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        diffFilter.biasVector = CIVector(x: -targetColor.x, y: -targetColor.y, z: -targetColor.z, w: 0)
        guard let diff = diffFilter.outputImage?.cropped(to: extent) else { return nil }

        // squared = diff * diff, component-wise (alpha along for the ride, unused below).
        let squareFilter = CIFilter.multiplyBlendMode()
        squareFilter.inputImage = diff
        squareFilter.backgroundImage = diff
        guard let squared = squareFilter.outputImage?.cropped(to: extent) else { return nil }

        // distanceSquared = dr² + dg² + db², broadcast into every output channel (R=G=B) so the
        // result already looks grayscale — `format: .L8` below just reads any one of them.
        let sumFilter = CIFilter.colorMatrix()
        sumFilter.inputImage = squared
        sumFilter.rVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        sumFilter.gVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        sumFilter.bVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        sumFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let distanceSquared = sumFilter.outputImage?.cropped(to: extent) else { return nil }

        // distance = sqrt(distanceSquared) — `CIGammaAdjust`'s `power: 0.5` is a per-component
        // `pow`, which for a non-negative input is exactly a square root.
        let sqrtFilter = CIFilter.gammaAdjust()
        sqrtFilter.inputImage = distanceSquared
        sqrtFilter.power = 0.5
        guard let distance = sqrtFilter.outputImage?.cropped(to: extent) else { return nil }

        // ramp = clamp((distance - threshold) / feather, 0, 1): 0 at/inside `threshold`, 1 at/past
        // `threshold + feather`, linear between. The non-inverted mask is `1 - ramp` (fully selected
        // at the sampled color, fading out); inverted flips that to select everything *outside* the
        // range instead.
        let featherSafe = max(Double(feather), 0.001)
        let scale = 1 / featherSafe
        let rampFilter = CIFilter.colorMatrix()
        rampFilter.inputImage = distance
        rampFilter.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        rampFilter.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        rampFilter.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        rampFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        rampFilter.biasVector = CIVector(x: -Double(threshold) * scale, y: -Double(threshold) * scale, z: -Double(threshold) * scale, w: 0)
        guard let rampRaw = rampFilter.outputImage?.cropped(to: extent) else { return nil }

        let clampFilter = CIFilter.colorClamp()
        clampFilter.inputImage = rampRaw
        clampFilter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clampFilter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let ramp = clampFilter.outputImage?.cropped(to: extent) else { return nil }

        let finalImage: CIImage
        if inverted {
            finalImage = ramp
        } else {
            let invertFilter = CIFilter.colorInvert()
            invertFilter.inputImage = ramp
            finalImage = invertFilter.outputImage?.cropped(to: extent) ?? ramp
        }

        return context.createCGImage(finalImage, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}
