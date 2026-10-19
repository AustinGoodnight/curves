import SwiftUI
import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import PhotoCatalog
import RawEngine

/// Replaces the plain preview `Image` in `EditorView`'s image pane while `EditorView
/// .paintedFillEditing` is set — paint a mask by hand (same brush mechanics as
/// `AssistedMaskEditorOverlay`: option-drag to erase, ⌘-drag to resize), then "Fill" runs it
/// through the same AI pipeline `RemoveObjectEditorOverlay` uses (`ObjectRemovalBaking`, the
/// vendored LaMa Core ML model) instead of Vision's click-to-select. For when the thing to remove
/// isn't a whole Vision-detected object — a stain, a sign, part of something — and a hand-drawn
/// mask targets it more precisely than an automatic instance selection can.
///
/// Reads/writes the *same* `asset.objectRemovalData` list `RemoveObjectEditorOverlay` does — these
/// are two mask-acquisition methods for one feature (AI-synthesized fill), not two separate lists,
/// so a removal added by either tool shows up (and can be deleted) in the other. Loads its own
/// working preview independent of `coordinator.previewImage`, with `crop` and `objectRemovals` both
/// forced off — same reasoning as `RemoveObjectEditorOverlay.loadBasePreview`.
struct PaintedFillEditorOverlay: View {
    let asset: PhotoAsset
    let activeStages: [Stage]
    let coordinator: EditorRenderCoordinator
    /// Called once, on both Done and Cancel — Done already wrote `asset.objectRemovalData` before
    /// calling it, Cancel never touched it.
    var onFinished: () -> Void

    @Environment(ColorSchemeStore.self) private var uiColors

    /// The un-object-removed, uncropped base render — see this type's doc comment.
    @State private var previewImage: CGImage?
    /// `previewImage` with every current `removals` entry composited on top — what's actually shown.
    @State private var displayImage: CGImage?
    @State private var removals: [ObjectRemoval] = []
    @State private var selectedRemovalID: UUID?

    /// The mask being painted right now, awaiting "Fill" — cleared (a fresh, empty canvas) after
    /// each bake so the next object can be painted. Same role as `AssistedMaskEditorOverlay
    /// .canvas`, just per-removal instead of per-stage.
    @State private var canvas: MaskCanvas?
    @State private var displayedMaskAlpha: CGImage?
    @State private var brushRadius: CGFloat = 28
    /// Cursor position in view space, for the brush-size guide circle — identical role to
    /// `AssistedMaskEditorOverlay.cursorLocation`.
    @State private var cursorLocation: CGPoint?
    @State private var resizeAnchor: (radius: CGFloat, location: CGPoint)?
    /// Resolved once per gesture, at its first `onChanged` call — matches
    /// `AssistedMaskEditorOverlay.resizeAnchor`/`GradientMaskEditorOverlay.activeHandle`'s "decide
    /// once, not every frame" pattern. Without this, a plain click would both paint a tiny dot
    /// *and* select whatever removal happens to be underneath it, since `DragGesture(minimumDistance:
    /// 0)` fires `onChanged` at least once even for a zero-movement click.
    @State private var dragIntent: DragIntent?

    private enum DragIntent: Equatable {
        case paint
        case select(UUID)
    }

    @State private var isFilling = false
    @State private var errorMessage: String?
    @State private var displayContext = CIContext()

    private static let brushRadiusRange: ClosedRange<CGFloat> = 6...120
    /// Pinch-to-zoom + scroll-to-pan while painting — see `ZoomPanState`'s doc comment.
    @State private var zoomPan = ZoomPanState()

    private var imageSize: CGSize {
        guard let previewImage else { return .zero }
        return CGSize(width: previewImage.width, height: previewImage.height)
    }

    var body: some View {
        GeometryReader { geometry in
                let baseFitRect = Self.aspectFitRect(imageSize: imageSize, in: geometry.size)
                let fitRect = zoomPan.apply(to: baseFitRect)
                ZStack {
                    if let displayImage {
                        Image(decorative: displayImage, scale: 1)
                            .resizable()
                            .frame(width: fitRect.width, height: fitRect.height)
                            .position(x: fitRect.midX, y: fitRect.midY)
                    }
                    overlayMarkers(fitRect: fitRect)
                    if let cursorLocation, fitRect.contains(cursorLocation) {
                        let viewRadius = brushRadius * fitRect.width / max(imageSize.width, 1)
                        Circle()
                            .stroke(Color.white, lineWidth: 1.5)
                            .background(Circle().stroke(Color.black.opacity(0.6), lineWidth: 3).padding(-1))
                            .frame(width: viewRadius * 2, height: viewRadius * 2)
                            .position(cursorLocation)
                            .allowsHitTesting(false)
                    }
                    ScrollWheelCatcher { delta in zoomPan.pan(by: delta) }
                    MagnifyCatcher { delta, location in zoomPan.magnify(by: delta, anchor: location, baseFitRect: baseFitRect) }
                    zoomPan.percentPill(containerSize: geometry.size)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
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
                                    Self.brushRadiusRange.upperBound, max(Self.brushRadiusRange.lowerBound, anchor.radius + delta)
                                )
                                return
                            }
                            resizeAnchor = nil
                            if dragIntent == nil {
                                if let startPointNorm = Self.imagePointNormalized(from: value.startLocation, fitRect: fitRect, imageSize: imageSize),
                                   let hit = removals.first(where: {
                                       CGRect(x: $0.cropX, y: $0.cropY, width: $0.cropWidth, height: $0.cropHeight).contains(startPointNorm)
                                   }) {
                                    dragIntent = .select(hit.id)
                                } else {
                                    dragIntent = .paint
                                }
                            }
                            guard dragIntent == .paint, let imagePoint = Self.imagePoint(from: value.location, fitRect: fitRect, imageSize: imageSize)
                            else { return }
                            paintBrush(at: imagePoint, subtracting: NSEvent.modifierFlags.contains(.option))
                        }
                        .onEnded { _ in
                            if case .select(let id) = dragIntent {
                                selectedRemovalID = id
                            } else if dragIntent == .paint {
                                selectedRemovalID = nil
                            }
                            dragIntent = nil
                            resizeAnchor = nil
                        }
                )
            }
            .padding()
        .overlay(alignment: .bottom) { toolbar }
        .task(id: asset.filePath) {
            loadGeometry()
            await loadBasePreview()
        }
    }

    // MARK: - Drawing

    @ViewBuilder
    private func overlayMarkers(fitRect: CGRect) -> some View {
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
        ForEach(removals) { removal in
            let rect = Self.viewRect(
                for: CGRect(x: removal.cropX, y: removal.cropY, width: removal.cropWidth, height: removal.cropHeight),
                fitRect: fitRect
            )
            Rectangle()
                .stroke(Color.white, style: StrokeStyle(lineWidth: removal.id == selectedRemovalID ? 2.5 : 1, dash: [5, 3]))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Paint over what to remove · Option-drag to erase · ⌘-drag to resize")
                .font(.caption)
                .foregroundStyle(.secondary)
            MinimalSlider(
                value: Binding(get: { Double(brushRadius) }, set: { brushRadius = CGFloat($0) }),
                range: Double(Self.brushRadiusRange.lowerBound)...Double(Self.brushRadiusRange.upperBound)
            )
            .frame(width: 100)
            if isFilling {
                ProgressView().controlSize(.small)
                Text("Generating fill…").font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Divider().frame(height: 16)
            Button("Fill") { fillPaintedMask() }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .disabled(displayedMaskAlpha == nil || isFilling)
            Button("Delete Selected") { deleteSelectedRemoval() }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .disabled(selectedRemovalID == nil)
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

    // MARK: - Interaction

    private func paintBrush(at imagePoint: CGPoint, subtracting: Bool) {
        canvas?.paintCircle(center: imagePoint, radius: brushRadius, erase: subtracting)
        updateDisplayedMaskAlpha()
    }

    private func fillPaintedMask() {
        guard let previewImage, let maskImage = canvas?.cgImage() else { return }
        errorMessage = nil
        isFilling = true
        let size = imageSize
        Task {
            defer { isFilling = false }
            do {
                let removal = try await Task.detached(priority: .userInitiated) {
                    try ObjectRemovalBaking.makeObjectRemoval(previewImage: previewImage, maskImage: maskImage, imageSize: size)
                }.value
                removals.append(removal)
                canvas = MaskCanvas(size: imageSize)
                updateDisplayedMaskAlpha()
                updateComposite()
            } catch {
                errorMessage = "Couldn't generate a fill for that area."
            }
        }
    }

    private func deleteSelectedRemoval() {
        guard let selectedRemovalID else { return }
        removals.removeAll { $0.id == selectedRemovalID }
        self.selectedRemovalID = nil
        updateComposite()
    }

    // MARK: - Live preview

    /// Re-runs `ObjectRemovalKernel` directly on `previewImage` — cheap, never touches the RAW
    /// decode/grade pipeline or the Core ML model. Same as `RemoveObjectEditorOverlay
    /// .updateComposite`.
    private func updateComposite() {
        guard let previewImage else {
            displayImage = nil
            return
        }
        guard !removals.isEmpty else {
            displayImage = previewImage
            return
        }
        let ciImage = CIImage(cgImage: previewImage)
        let output = ObjectRemovalKernel.apply(to: ciImage, params: ObjectRemovalParameters(removals: removals))
        displayImage = displayContext.createCGImage(output, from: ciImage.extent) ?? previewImage
    }

    /// Same `CIMaskToAlpha` conversion `AssistedMaskEditorOverlay.updateDisplayedMask` uses.
    private func updateDisplayedMaskAlpha() {
        guard let mask = canvas?.cgImage() else {
            displayedMaskAlpha = nil
            return
        }
        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = CIImage(cgImage: mask)
        displayedMaskAlpha = toAlpha.outputImage.flatMap { displayContext.createCGImage($0, from: $0.extent) }
    }

    /// Same "force off the fields this overlay itself controls" approach as
    /// `RemoveObjectEditorOverlay.loadBasePreview`.
    private func loadBasePreview() async {
        var baseParams = rawBaseParameters(for: asset)
        baseParams.crop = nil
        baseParams.objectRemovals = nil
        let stageStack = activeStages.map { stageParameters(for: $0, detailEnabled: asset.editDetailEnabled) }
        let renderer = coordinator.renderer
        let image = await Task.detached(priority: .userInitiated) {
            renderer.renderPreview(baseParams: baseParams, stageStack: stageStack, maxPixelSize: 1600)
        }.value
        previewImage = image
        canvas = MaskCanvas(size: imageSize)
        updateDisplayedMaskAlpha()
        updateComposite()
    }

    // MARK: - Geometry loading / saving

    private func loadGeometry() {
        if let data = asset.objectRemovalData, let decoded = try? JSONDecoder().decode([ObjectRemoval].self, from: data) {
            removals = decoded
        } else {
            removals = []
        }
        selectedRemovalID = nil
    }

    private func finish() {
        defer { onFinished() }
        guard !removals.isEmpty else {
            asset.objectRemovalData = nil
            return
        }
        asset.objectRemovalData = try? JSONEncoder().encode(removals)
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

    /// Pixel-space (not normalized) — matches `AssistedMaskEditorOverlay.imagePoint`'s own
    /// convention, since `MaskCanvas.paintCircle` works in image pixels.
    private static func imagePoint(from viewPoint: CGPoint, fitRect: CGRect, imageSize: CGSize) -> CGPoint? {
        guard fitRect.width > 0, fitRect.height > 0, fitRect.insetBy(dx: -1, dy: -1).contains(viewPoint) else { return nil }
        let relX = (viewPoint.x - fitRect.minX) / fitRect.width
        let relY = (viewPoint.y - fitRect.minY) / fitRect.height
        return CGPoint(x: min(max(relX, 0), 1) * imageSize.width, y: min(max(relY, 0), 1) * imageSize.height)
    }

    private static func imagePointNormalized(from viewPoint: CGPoint, fitRect: CGRect, imageSize: CGSize) -> CGPoint? {
        guard fitRect.width > 0, fitRect.height > 0, fitRect.insetBy(dx: -1, dy: -1).contains(viewPoint) else { return nil }
        let relX = (viewPoint.x - fitRect.minX) / fitRect.width
        let relY = (viewPoint.y - fitRect.minY) / fitRect.height
        return CGPoint(x: min(max(relX, 0), 1), y: min(max(relY, 0), 1))
    }

    private static func viewRect(for normalized: CGRect, fitRect: CGRect) -> CGRect {
        CGRect(
            x: fitRect.minX + normalized.minX * fitRect.width, y: fitRect.minY + normalized.minY * fitRect.height,
            width: normalized.width * fitRect.width, height: normalized.height * fitRect.height
        )
    }
}
