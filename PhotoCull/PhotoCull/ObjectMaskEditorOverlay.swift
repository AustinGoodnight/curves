import SwiftUI
import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import PhotoCatalog

/// Replaces the plain preview `Image` in `EditorView`'s image pane while `EditorView
/// .objectMaskEditingStage` is set — click an object to add its Vision-detected silhouette to the
/// mask, option-click to remove one, building a selection out of whole detected subjects/objects
/// rather than brush strokes or a sampled color range. "Done" bakes the result into
/// `stage.maskData`, same as `AssistedMaskEditorOverlay.finish()`. Shares its actual segmentation
/// work with the Remove Object tool's selection step — see `ObjectSelectionMask.Session`'s doc
/// comment — this overlay is just a different destination for the same masks (a `Stage`'s grading
/// mask instead of an `ObjectRemoval`'s inpainting input).
struct ObjectMaskEditorOverlay: View {
    let stage: Stage
    let previewImage: CGImage
    /// Called once, on both Done and Cancel — Done already wrote `stage.maskData` before calling
    /// it, Cancel never touched it.
    var onFinished: () -> Void

    @Environment(ColorSchemeStore.self) private var uiColors

    /// One Vision segmentation pass, reused across every click on this photo — see
    /// `ObjectSelectionMask.Session`'s doc comment.
    @State private var session: ObjectSelectionMask.Session?
    /// The accumulated selection so far — `nil` means empty, same "nothing baked yet" meaning as
    /// `AssistedMaskEditorOverlay`'s canvas starting blank.
    @State private var maskImage: CGImage?
    @State private var displayedMaskAlpha: CGImage?
    @State private var isSelecting = false
    @State private var errorMessage: String?
    @State private var displayContext = CIContext()

    private var imageSize: CGSize {
        CGSize(width: previewImage.width, height: previewImage.height)
    }

    /// Pinch-to-zoom + scroll-to-pan while selecting objects — see `ZoomPanState`'s doc comment.
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
                    // `DragGesture(minimumDistance: 0)`, not `.onTapGesture` — matches
                    // `ColorRangeMaskEditorOverlay`'s identical reasoning: plain SwiftUI tap
                    // gestures never expose a location, and a zero-minimum-distance drag's
                    // `.onEnded` still fires exactly once per click.
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            guard let imagePoint = Self.imagePointNormalized(from: value.location, fitRect: fitRect, imageSize: imageSize) else { return }
                            selectObject(at: imagePoint, subtract: NSEvent.modifierFlags.contains(.option))
                        }
                )
            }
            .padding()
        .overlay(alignment: .bottom) { toolbar }
        .task(id: stage.id) {
            loadGeometry()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Click an object to add it to the mask · Option-click to remove")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isSelecting {
                ProgressView().controlSize(.small)
                Text("Selecting…").font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Divider().frame(height: 16)
            Button("Clear") {
                maskImage = nil
                displayedMaskAlpha = nil
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(maskImage == nil)
            Button("Cancel") { onFinished() }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            Button("Done") { finish() }
                .buttonStyle(.plain)
                .foregroundStyle(uiColors.accentColor)
                .disabled(maskImage == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 10)
    }

    // MARK: - Interaction

    private func selectObject(at imagePoint: CGPoint, subtract: Bool) {
        errorMessage = nil
        isSelecting = true
        let existingSession = session
        let existingMask = maskImage
        let size = imageSize
        let capturedPreview = previewImage
        Task {
            defer { isSelecting = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> (ObjectSelectionMask.Session, CGImage?) in
                    let activeSession = try existingSession ?? ObjectSelectionMask.Session(image: capturedPreview)
                    let newMask = try activeSession.mask(at: imagePoint)
                    let combined = ObjectMaskGenerator.combine(existing: existingMask, with: newMask, subtract: subtract, imageSize: size)
                    return (activeSession, combined)
                }.value
                session = result.0
                maskImage = result.1
                updateDisplayedMaskAlpha()
            } catch let error as ObjectSelectionMask.SelectionError {
                switch error {
                case .noInstancesDetected: errorMessage = "No distinct objects found in this photo."
                case .pointNotOnAnyInstance: errorMessage = "No object detected there — try clicking directly on it."
                case .maskGenerationFailed: errorMessage = "Couldn't generate a mask for that object."
                }
            } catch {
                errorMessage = "No object detected there — try clicking directly on it."
            }
        }
    }

    private func updateDisplayedMaskAlpha() {
        guard let maskImage else {
            displayedMaskAlpha = nil
            return
        }
        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = CIImage(cgImage: maskImage)
        displayedMaskAlpha = toAlpha.outputImage.flatMap { displayContext.createCGImage($0, from: $0.extent) }
    }

    // MARK: - Geometry loading / saving

    private func loadGeometry() {
        if let data = stage.maskData, let decoded = Self.decodePNG(data) {
            maskImage = decoded
        } else {
            maskImage = nil
        }
        updateDisplayedMaskAlpha()
        session = nil
    }

    private func finish() {
        defer { onFinished() }
        guard let maskImage, let data = Self.pngData(from: maskImage) else { return }
        stage.maskData = data
    }

    // MARK: - Coordinate mapping / encoding

    private static func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (containerSize.width - fittedSize.width) / 2, y: (containerSize.height - fittedSize.height) / 2)
        return CGRect(origin: origin, size: fittedSize)
    }

    private static func imagePointNormalized(from viewPoint: CGPoint, fitRect: CGRect, imageSize: CGSize) -> CGPoint? {
        guard fitRect.width > 0, fitRect.height > 0, fitRect.insetBy(dx: -1, dy: -1).contains(viewPoint) else { return nil }
        let relX = (viewPoint.x - fitRect.minX) / fitRect.width
        let relY = (viewPoint.y - fitRect.minY) / fitRect.height
        return CGPoint(x: min(max(relX, 0), 1), y: min(max(relY, 0), 1))
    }

    private static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Combines a newly Vision-selected instance mask into (or out of) the working selection —
/// standalone, same "one-shot bake, not a render-path stage" reasoning as `ColorRangeMaskGenerator`.
enum ObjectMaskGenerator {
    /// Union (lighten blend, i.e. per-pixel max) to add, or subtract (darken-blend the existing
    /// mask against the new mask inverted, i.e. per-pixel min against `1 - newMask`) to remove.
    /// Rescales `existing` to `imageSize` first if it's a different size — same "don't assume mask
    /// and image already match resolution" caution as `RawImageRenderer.applyMask`.
    static func combine(existing: CGImage?, with newMask: CGImage, subtract: Bool, imageSize: CGSize) -> CGImage? {
        let extent = CGRect(origin: .zero, size: imageSize)
        guard extent.width > 0, extent.height > 0 else { return nil }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let newCI = CIImage(cgImage: newMask)

        guard let existing else {
            guard !subtract else { return nil }
            return context.createCGImage(newCI, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }

        let existingSource = CIImage(cgImage: existing)
        let existingExtent = existingSource.extent
        let existingScaled: CIImage
        if existingExtent.width > 0, existingExtent.height > 0, existingExtent.size != extent.size {
            let scale = CGAffineTransform(scaleX: extent.width / existingExtent.width, y: extent.height / existingExtent.height)
            existingScaled = existingSource.transformed(by: scale)
        } else {
            existingScaled = existingSource
        }

        let result: CIImage
        if subtract {
            let invert = CIFilter.colorInvert()
            invert.inputImage = newCI
            let invertedNew = invert.outputImage?.cropped(to: extent) ?? newCI
            let darken = CIFilter.darkenBlendMode()
            darken.inputImage = existingScaled
            darken.backgroundImage = invertedNew
            result = darken.outputImage?.cropped(to: extent) ?? existingScaled
        } else {
            let lighten = CIFilter.lightenBlendMode()
            lighten.inputImage = existingScaled
            lighten.backgroundImage = newCI
            result = lighten.outputImage?.cropped(to: extent) ?? existingScaled
        }
        return context.createCGImage(result, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}
