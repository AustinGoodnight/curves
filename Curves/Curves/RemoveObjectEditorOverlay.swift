import SwiftUI
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import PhotoCatalog
import RawEngine

/// Replaces the plain preview `Image` in `EditorView`'s image pane while `EditorView
/// .objectRemovalEditing` is set — click an unwanted object to select it (Vision-based, see
/// `ObjectSelectionMask`), then "Remove" runs it through the vendored LaMa Core ML model
/// (`RawEngine`'s `InpaintingFilter`) to synthesize a fill. Kept as a separate tool from
/// `SpotRemovalEditorOverlay`'s manual clone/heal brush, not a replacement for it — see this
/// feature's plan doc for why both exist. Asset-level, not per-`Stage`, same reasoning as
/// `SpotRemovalEditorOverlay` (see `ObjectRemoval`'s doc comment on `RawEngine`).
///
/// Loads its own working preview independent of `coordinator.previewImage`, with `crop` and
/// `objectRemovals` both forced off — same "show the frame to work from, not what this overlay
/// itself would produce" reasoning as `SpotRemovalEditorOverlay.loadBasePreview`. Every further
/// edit (placing a mask, running the model) only ever touches that cached `CGImage` directly, never
/// re-triggering the RAW decode/grade pipeline.
struct RemoveObjectEditorOverlay: View {
    let asset: PhotoAsset
    let activeStages: [Stage]
    let coordinator: EditorRenderCoordinator
    /// Called once, on both Done and Cancel — Done already wrote `asset.objectRemovalData` before
    /// calling it, Cancel never touched it.
    var onFinished: () -> Void

    @Environment(ColorSchemeStore.self) private var uiColors

    /// The un-object-removed, uncropped base render — see this type's doc comment. Already
    /// reflects Spot Removal (if any), since that stage runs earlier in the pipeline than this one.
    @State private var previewImage: CGImage?
    /// `previewImage` with every current `removals` entry composited on top — what's actually shown.
    @State private var displayImage: CGImage?
    @State private var removals: [ObjectRemoval] = []
    @State private var selectedRemovalID: UUID?

    /// One Vision segmentation pass, reused across every click on this photo — see
    /// `ObjectSelectionMask.Session`'s doc comment.
    @State private var session: ObjectSelectionMask.Session?
    /// The most recently Vision-selected mask, awaiting either "Remove" (bakes it into a new
    /// `ObjectRemoval`) or a different click (replaces it). `nil` once committed or on failure.
    @State private var pendingMaskImage: CGImage?
    @State private var pendingMaskAlpha: CGImage?

    @State private var isSelecting = false
    @State private var isRemoving = false
    @State private var errorMessage: String?
    @State private var displayContext = CIContext()

    private var imageSize: CGSize {
        guard let previewImage else { return .zero }
        return CGSize(width: previewImage.width, height: previewImage.height)
    }

    /// Pinch-to-zoom + scroll-to-pan while selecting objects — see `ZoomPanState`'s doc comment.
    @State private var zoomPan = ZoomPanState()

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
                    ScrollWheelCatcher { delta in zoomPan.pan(by: delta) }
                    MagnifyCatcher { delta, location in zoomPan.magnify(by: delta, anchor: location, baseFitRect: baseFitRect) }
                    zoomPan.percentPill(containerSize: geometry.size)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            guard let imagePoint = Self.imagePointNormalized(from: value.location, fitRect: fitRect, imageSize: imageSize) else { return }
                            handleTap(at: imagePoint)
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
        if let pendingMaskAlpha {
            Color.cyan.opacity(0.5)
                .mask(
                    Image(decorative: pendingMaskAlpha, scale: 1)
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
            Text("Click an object to select it, then Remove · click a dashed box to select it for deletion")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isSelecting {
                ProgressView().controlSize(.small)
                Text("Selecting…").font(.caption).foregroundStyle(.secondary)
            } else if isRemoving {
                ProgressView().controlSize(.small)
                Text("Generating fill…").font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Divider().frame(height: 16)
            Button("Remove") { removeSelectedObject() }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .disabled(pendingMaskImage == nil || isRemoving)
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

    private func handleTap(at imagePoint: CGPoint) {
        if let hit = removals.first(where: {
            CGRect(x: $0.cropX, y: $0.cropY, width: $0.cropWidth, height: $0.cropHeight).contains(imagePoint)
        }) {
            selectedRemovalID = hit.id
            return
        }
        selectedRemovalID = nil
        selectObject(at: imagePoint)
    }

    /// Creates the Vision `Session` on first use (the expensive part — a full segmentation pass
    /// over the photo), then reuses it for every subsequent click, matching this type's own doc
    /// comment.
    private func selectObject(at imagePoint: CGPoint) {
        guard let previewImage else { return }
        errorMessage = nil
        isSelecting = true
        let existingSession = session
        Task {
            defer { isSelecting = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> (ObjectSelectionMask.Session, CGImage) in
                    let activeSession = try existingSession ?? ObjectSelectionMask.Session(image: previewImage)
                    let mask = try activeSession.mask(at: imagePoint)
                    return (activeSession, mask)
                }.value
                session = result.0
                pendingMaskImage = result.1
                updatePendingMaskAlpha()
            } catch let error as ObjectSelectionMask.SelectionError {
                pendingMaskImage = nil
                pendingMaskAlpha = nil
                switch error {
                case .noInstancesDetected:
                    errorMessage = "No distinct objects found in this photo."
                case .pointNotOnAnyInstance:
                    errorMessage = "No object detected there — try clicking directly on it."
                case .maskGenerationFailed:
                    errorMessage = "Couldn't generate a mask for that object."
                }
            } catch {
                pendingMaskImage = nil
                pendingMaskAlpha = nil
                errorMessage = "No object detected there — try clicking directly on it."
            }
        }
    }

    private func removeSelectedObject() {
        guard let previewImage, let pendingMaskImage else { return }
        errorMessage = nil
        isRemoving = true
        let size = imageSize
        Task {
            defer { isRemoving = false }
            do {
                let removal = try await Task.detached(priority: .userInitiated) {
                    try ObjectRemovalBaking.makeObjectRemoval(previewImage: previewImage, maskImage: pendingMaskImage, imageSize: size)
                }.value
                removals.append(removal)
                self.pendingMaskImage = nil
                self.pendingMaskAlpha = nil
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

    /// Re-runs `ObjectRemovalKernel` directly on `previewImage` — cheap (a handful of blend passes
    /// at preview resolution), never touches the RAW decode/grade pipeline or the Core ML model.
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

    private func updatePendingMaskAlpha() {
        guard let pendingMaskImage else {
            pendingMaskAlpha = nil
            return
        }
        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = CIImage(cgImage: pendingMaskImage)
        pendingMaskAlpha = toAlpha.outputImage.flatMap { displayContext.createCGImage($0, from: $0.extent) }
    }

    /// Same "force off the fields this overlay itself controls" approach as
    /// `SpotRemovalEditorOverlay.loadBasePreview` — see this type's doc comment for why both `crop`
    /// and `objectRemovals` have to be nil here.
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
        pendingMaskImage = nil
        pendingMaskAlpha = nil
        session = nil
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
