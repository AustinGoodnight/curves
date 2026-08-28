import SwiftUI
import AppKit
import CoreGraphics
import CoreImage
import PhotoCatalog
import RawEngine

/// Replaces the plain preview `Image` in `EditorView`'s image pane while `EditorView
/// .spotRemovalEditing` is set — click to heal a blemish/dust spot, drag its dashed "source" handle
/// to resample from somewhere else, "Done" writes the whole spot list to `asset.spotRemovalData`.
/// Asset-level, not per-`Stage` (same reasoning as `CropEditorOverlay` — see `CropParameters`'s doc
/// comment), so like that overlay this reads/writes `asset` directly.
///
/// Renders its own working preview independent of `coordinator.previewImage`, with `crop` *and*
/// `spotRemoval` both forced off — same "show the full, unhealed frame to work from" reasoning as
/// `CropEditorOverlay.loadUncroppedPreview`, and necessary here for a second reason: every spot's
/// `targetX`/`sourceX`/etc. are normalized to that full pre-crop frame (see `SpotRemoval`'s doc
/// comment on `RawEngine`), so the working canvas has to be that same frame or newly-placed spots
/// would land in the wrong place once actually rendered. Once loaded, further spot edits never
/// re-run the RAW decode/grade pipeline — they just re-run `SpotRemovalKernel` directly on the
/// already-rendered base `CGImage`, the same "cheap local recompute, not a full render" shape as
/// `GradientMaskEditorOverlay.updateMask()`.
struct SpotRemovalEditorOverlay: View {
    let asset: PhotoAsset
    let activeStages: [Stage]
    let coordinator: EditorRenderCoordinator
    /// Called once, on both Done and Cancel — Done already wrote `asset.spotRemovalData` before
    /// calling it, Cancel never touched it.
    var onFinished: () -> Void

    /// The unhealed, uncropped base render — see this type's doc comment.
    @State private var previewImage: CGImage?
    /// `previewImage` with every current spot in `spots` composited on top — what's actually shown.
    @State private var displayImage: CGImage?
    @State private var spots: [SpotRemoval] = []
    @State private var selectedSpotID: UUID?
    /// Radius (in `previewImage`-pixel units, matching `AssistedMaskEditorOverlay.brushRadius`'s own
    /// convention) used for the *next* spot placed — editing an existing spot's radius instead
    /// updates that spot directly, see `radiusBinding`.
    @State private var brushRadius: CGFloat = 40
    @State private var displayContext = CIContext()
    /// Cursor position in view space, for the brush-size guide circle — see
    /// `AssistedMaskEditorOverlay.cursorLocation`'s identical doc comment.
    @State private var cursorLocation: CGPoint?
    @State private var dragKind: DragKind?

    private enum SpotPart { case target, source }
    private enum DragKind {
        case existing(id: UUID, part: SpotPart)
        /// Anchored the same way `AssistedMaskEditorOverlay.resizeAnchor` is — captured once at
        /// the start of a command-held drag so the whole drag's vertical delta maps to a size
        /// change relative to where it began.
        case resizeBrush(radius: CGFloat, location: CGPoint)
    }

    private static let handleHitRadius: CGFloat = 20
    private static let brushRadiusRange: ClosedRange<CGFloat> = 8...120

    private var imageSize: CGSize {
        guard let previewImage else { return .zero }
        return CGSize(width: previewImage.width, height: previewImage.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let fitRect = Self.aspectFitRect(imageSize: imageSize, in: geometry.size)
                ZStack {
                    if let displayImage {
                        Image(decorative: displayImage, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    spotHandles(fitRect: fitRect)
                    if let cursorLocation, dragKind == nil, fitRect.contains(cursorLocation) {
                        let viewRadius = brushRadius * fitRect.width / max(imageSize.width, 1)
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
                            handleDrag(value: value, fitRect: fitRect)
                        }
                        .onEnded { _ in dragKind = nil }
                )
            }
            .padding()

            toolbar
        }
        .task(id: asset.filePath) {
            loadGeometry()
            await loadBasePreview()
        }
    }

    // MARK: - Drawing

    @ViewBuilder
    private func spotHandles(fitRect: CGRect) -> some View {
        ForEach(spots) { spot in
            let targetView = Self.viewPoint(for: CGPoint(x: spot.targetX, y: spot.targetY), fitRect: fitRect)
            let sourceView = Self.viewPoint(for: CGPoint(x: spot.sourceX, y: spot.sourceY), fitRect: fitRect)
            let viewRadius = spot.radius * fitRect.width
            let selected = spot.id == selectedSpotID
            Path { path in
                path.move(to: targetView)
                path.addLine(to: sourceView)
            }
            .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .allowsHitTesting(false)
            Circle()
                .stroke(Color.white, lineWidth: selected ? 2.5 : 1.5)
                .frame(width: viewRadius * 2, height: viewRadius * 2)
                .position(targetView)
                .allowsHitTesting(false)
            Circle()
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: [5, 3]))
                .frame(width: viewRadius * 2, height: viewRadius * 2)
                .position(sourceView)
                .allowsHitTesting(false)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Click to heal a spot · drag the dashed circle to resample · ⌘-drag to resize")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Radius")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: radiusBinding, in: Self.brushRadiusRange) { Text("Radius") }
                .frame(width: 140)
            Spacer()
            Button("Delete Spot") { deleteSelectedSpot() }
                .disabled(selectedSpotID == nil)
            Button("Cancel") { onFinished() }
            Button("Done") { finish() }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.thinMaterial)
    }

    /// Doubles as "size of the next new spot" and "size of the selected spot" — matching how
    /// `GradientMaskEditorOverlay`'s Feather slider is bound to whichever geometry is currently in
    /// play rather than needing two separate controls.
    private var radiusBinding: Binding<CGFloat> {
        Binding(
            get: {
                if let selectedSpotID, let spot = spots.first(where: { $0.id == selectedSpotID }) {
                    return spot.radius * max(imageSize.width, 1)
                }
                return brushRadius
            },
            set: { newValue in
                brushRadius = newValue
                guard let selectedSpotID, let index = spots.firstIndex(where: { $0.id == selectedSpotID }) else { return }
                spots[index].radius = newValue / max(imageSize.width, 1)
                updateComposite()
            }
        )
    }

    // MARK: - Interaction

    /// Resolved once per gesture, at its first `onChanged` call (matching every other overlay's
    /// "decide the anchor/handle once" pattern — see e.g. `AssistedMaskEditorOverlay.resizeAnchor`):
    /// dragging an existing handle takes priority over placing a new spot, then a command-held drag
    /// anywhere resizes the default brush, and otherwise the click places a brand-new spot right
    /// where it started so the rest of the drag can immediately reposition it before release.
    private func handleDrag(value: DragGesture.Value, fitRect: CGRect) {
        if dragKind == nil {
            if let hit = Self.nearestHandle(to: value.startLocation, spots: spots, fitRect: fitRect) {
                dragKind = .existing(id: hit.id, part: hit.part)
                selectedSpotID = hit.id
            } else if NSEvent.modifierFlags.contains(.command) {
                dragKind = .resizeBrush(radius: brushRadius, location: value.startLocation)
            } else if let imagePoint = Self.imagePointNormalized(from: value.startLocation, fitRect: fitRect, imageSize: imageSize) {
                let newSpot = makeSpot(at: imagePoint)
                spots.append(newSpot)
                selectedSpotID = newSpot.id
                dragKind = .existing(id: newSpot.id, part: .target)
                updateComposite()
            }
        }
        guard let dragKind else { return }
        switch dragKind {
        case .existing(let id, let part):
            guard let imagePoint = Self.imagePointNormalized(from: value.location, fitRect: fitRect, imageSize: imageSize),
                  let index = spots.firstIndex(where: { $0.id == id }) else { return }
            switch part {
            case .target:
                spots[index].targetX = imagePoint.x
                spots[index].targetY = imagePoint.y
            case .source:
                spots[index].sourceX = imagePoint.x
                spots[index].sourceY = imagePoint.y
            }
            updateComposite()
        case .resizeBrush(let radius, let location):
            let delta = location.y - value.location.y
            brushRadius = min(Self.brushRadiusRange.upperBound, max(Self.brushRadiusRange.lowerBound, radius + delta))
        }
    }

    /// Default source point offset horizontally from the new spot's target by 2.5x its radius,
    /// flipped to the other side when that would land too close to the image's right edge — a
    /// reasonable "somewhere nearby and probably clean" starting guess the user can always drag
    /// to a better spot afterward, not an attempt at automatic content-aware matching.
    private func makeSpot(at imagePoint: CGPoint) -> SpotRemoval {
        let radiusNorm = brushRadius / max(imageSize.width, 1)
        var sourceX = imagePoint.x + radiusNorm * 2.5
        if sourceX > 0.95 { sourceX = imagePoint.x - radiusNorm * 2.5 }
        sourceX = min(max(sourceX, 0.02), 0.98)
        return SpotRemoval(targetX: imagePoint.x, targetY: imagePoint.y, sourceX: sourceX, sourceY: imagePoint.y, radius: radiusNorm)
    }

    private func deleteSelectedSpot() {
        guard let selectedSpotID else { return }
        spots.removeAll { $0.id == selectedSpotID }
        self.selectedSpotID = nil
        updateComposite()
    }

    private static func nearestHandle(to location: CGPoint, spots: [SpotRemoval], fitRect: CGRect) -> (id: UUID, part: SpotPart)? {
        var best: (id: UUID, part: SpotPart, distance: CGFloat)?
        for spot in spots {
            let targetView = viewPoint(for: CGPoint(x: spot.targetX, y: spot.targetY), fitRect: fitRect)
            let sourceView = viewPoint(for: CGPoint(x: spot.sourceX, y: spot.sourceY), fitRect: fitRect)
            let viewRadius = spot.radius * fitRect.width
            let dSource = hypot(location.x - sourceView.x, location.y - sourceView.y)
            if dSource <= handleHitRadius, best == nil || dSource < best!.distance {
                best = (spot.id, .source, dSource)
            }
            let dTarget = hypot(location.x - targetView.x, location.y - targetView.y)
            if dTarget <= max(handleHitRadius, viewRadius), best == nil || dTarget < best!.distance {
                best = (spot.id, .target, dTarget)
            }
        }
        return best.map { ($0.id, $0.part) }
    }

    // MARK: - Live preview

    /// Re-runs `SpotRemovalKernel` directly on `previewImage` — cheap (a handful of blend passes at
    /// preview resolution), never touches the RAW decode/grade pipeline. See this type's doc
    /// comment for why that split is safe.
    private func updateComposite() {
        guard let previewImage else {
            displayImage = nil
            return
        }
        guard !spots.isEmpty else {
            displayImage = previewImage
            return
        }
        let ciImage = CIImage(cgImage: previewImage)
        let output = SpotRemovalKernel.apply(to: ciImage, params: SpotRemovalParameters(spots: spots))
        displayImage = displayContext.createCGImage(output, from: ciImage.extent) ?? previewImage
    }

    /// Same "force off the fields this overlay itself controls" approach as
    /// `CropEditorOverlay.loadUncroppedPreview` — see this type's doc comment for why both `crop`
    /// and `spotRemoval` have to be nil here, not just `spotRemoval`.
    private func loadBasePreview() async {
        var baseParams = rawBaseParameters(for: asset)
        baseParams.crop = nil
        baseParams.spotRemoval = nil
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
        if let data = asset.spotRemovalData, let decoded = try? JSONDecoder().decode([SpotRemoval].self, from: data) {
            spots = decoded
        } else {
            spots = []
        }
        selectedSpotID = nil
    }

    private func finish() {
        defer { onFinished() }
        guard !spots.isEmpty else {
            asset.spotRemovalData = nil
            return
        }
        asset.spotRemovalData = try? JSONEncoder().encode(spots)
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
        guard fitRect.width > 0, fitRect.height > 0 else { return nil }
        let relX = (viewPoint.x - fitRect.minX) / fitRect.width
        let relY = (viewPoint.y - fitRect.minY) / fitRect.height
        return CGPoint(x: min(max(relX, 0), 1), y: min(max(relY, 0), 1))
    }

    private static func viewPoint(for normalized: CGPoint, fitRect: CGRect) -> CGPoint {
        CGPoint(x: fitRect.minX + normalized.x * fitRect.width, y: fitRect.minY + normalized.y * fitRect.height)
    }
}
