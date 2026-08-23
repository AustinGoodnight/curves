import SwiftUI
import PhotoCatalog
import RawEngine

/// Replaces the plain preview `Image` in `EditorView`'s image pane while `EditorView.cropEditing`
/// is set — straighten (rotate) plus a draggable crop rectangle, with a grid overlay to help line
/// up a horizon or composition. Asset-level, not per-`Stage` (see `CropParameters`'s doc comment),
/// so unlike `GradientMaskEditorOverlay`/`AssistedMaskEditorOverlay` this reads/writes `asset`
/// directly rather than a `Stage`.
///
/// The crop rectangle lives in the coordinate frame of the *rotated* image (`CropParameters.rect`'s
/// own convention) — visually, the photo rotates live under `.rotationEffect` while the crop
/// rectangle's handles stay axis-aligned on screen, exactly like Lightroom's straighten-while-
/// cropping interaction: you're always looking at the final, axis-aligned output framing, with the
/// photo turning underneath it.
///
/// Every candidate rect (from a handle drag, an aspect-lock change, or a straighten-angle change) is
/// checked against `CropTransform`'s inscribed-rectangle safety test before being committed — the
/// same "never let the user select a region that would sample outside the original photo" reasoning
/// as `LensCorrectionKernel`'s auto-scale step, just for a plain rotation instead of a lens
/// distortion polynomial. A rejected drag simply doesn't move that step, which reads as the crop box
/// gently stopping at the safe boundary rather than showing blank corners.
struct CropEditorOverlay: View {
    let asset: PhotoAsset
    /// Threaded through only to build an *uncropped* preview render for this overlay — see
    /// `loadUncroppedPreview`'s doc comment for why this can't just reuse `coordinator.previewImage`
    /// directly the way `GradientMaskEditorOverlay` reuses its own `previewImage` parameter.
    let activeStages: [Stage]
    let coordinator: EditorRenderCoordinator
    var onFinished: () -> Void

    /// This overlay's own preview render, deliberately independent of `coordinator.previewImage` —
    /// see `loadUncroppedPreview`.
    @State private var previewImage: CGImage?

    @State private var angleDegrees: Double = 0
    /// Normalized (0...1) crop rect in the *rotated* image's frame — see `CropParameters.rect`.
    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspectLock: AspectOption = .freeform
    @State private var gridStyle: GridStyle = .thirds
    @State private var activeHandle: Handle?
    /// Captured once at the start of a resize/move drag so every `onChanged` call computes the new
    /// rect from the same fixed starting point rather than compounding per-frame deltas — matches
    /// `GradientMaskEditorOverlay`'s "decide the anchor once per gesture" pattern.
    @State private var dragStartRect: CGRect?

    enum AspectOption: String, CaseIterable, Identifiable {
        case freeform = "Freeform"
        case original = "Original"
        case square = "1:1"
        case r4x5 = "4:5"
        case r5x4 = "5:4"
        case r16x9 = "16:9"
        case r9x16 = "9:16"
        case r3x2 = "3:2"
        case r2x3 = "2:3"
        var id: String { rawValue }
        /// Width / height, `nil` for freeform and for "Original" (which instead reads the photo's
        /// own unrotated aspect at the call site — the ratio depends on `imageSize`, not a constant).
        var ratio: Double? {
            switch self {
            case .freeform, .original: return nil
            case .square: return 1
            case .r4x5: return 4.0 / 5
            case .r5x4: return 5.0 / 4
            case .r16x9: return 16.0 / 9
            case .r9x16: return 9.0 / 16
            case .r3x2: return 3.0 / 2
            case .r2x3: return 2.0 / 3
            }
        }
    }

    enum GridStyle: String, CaseIterable, Identifiable {
        case none = "None"
        case thirds = "Thirds"
        case grid = "Grid"
        case diagonals = "Diagonals"
        case goldenRatio = "Golden Ratio"
        var id: String { rawValue }
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move
    }

    private static let handleHitRadius: CGFloat = 24

    private var imageSize: CGSize {
        guard let previewImage else { return .zero }
        return CGSize(width: previewImage.width, height: previewImage.height)
    }

    private var rotatedSize: CGSize {
        Self.rotatedSize(originalSize: imageSize, angleDegrees: angleDegrees)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let previewImage {
                GeometryReader { geometry in
                    let fitRect = Self.aspectFitRect(imageSize: rotatedSize, in: geometry.size)
                    let scale = rotatedSize.width > 0 ? fitRect.width / rotatedSize.width : 1
                    let viewCropRect = Self.viewRect(for: cropRect, fitRect: fitRect)
                    ZStack {
                        Image(decorative: previewImage, scale: 1)
                            .resizable()
                            .frame(width: imageSize.width * scale, height: imageSize.height * scale)
                            .rotationEffect(.degrees(angleDegrees))
                            .position(x: fitRect.midX, y: fitRect.midY)
                        scrim(containerSize: geometry.size, cropRect: viewCropRect)
                        gridOverlay(in: viewCropRect)
                        Rectangle()
                            .stroke(Color.white, lineWidth: 1.5)
                            .frame(width: viewCropRect.width, height: viewCropRect.height)
                            .position(x: viewCropRect.midX, y: viewCropRect.midY)
                            .allowsHitTesting(false)
                        handleDots(in: viewCropRect)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if activeHandle == nil {
                                    activeHandle = Self.nearestHandle(to: value.startLocation, cropRect: viewCropRect)
                                    dragStartRect = cropRect
                                }
                                guard let handle = activeHandle, let startRect = dragStartRect else { return }
                                let dxNorm = (value.translation.width) / max(fitRect.width, 1)
                                let dyNorm = (value.translation.height) / max(fitRect.height, 1)
                                let candidate = Self.resized(
                                    startRect, handle: handle, dxNorm: dxNorm, dyNorm: dyNorm,
                                    aspect: currentAspectRatio
                                )
                                if Self.isRectSafe(candidate, angleDegrees: angleDegrees, originalSize: imageSize, rotatedSize: rotatedSize) {
                                    cropRect = candidate
                                }
                            }
                            .onEnded { _ in
                                activeHandle = nil
                                dragStartRect = nil
                            }
                    )
                }
                .padding()
            } else {
                ProgressView("Loading…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            toolbar
        }
        .task(id: asset.id) {
            loadGeometry()
            await loadUncroppedPreview()
        }
    }

    /// Renders this overlay's own preview with `crop: nil` forced, independent of whatever
    /// `coordinator.previewImage` currently shows. Necessary because `coordinator`'s own render
    /// pipeline applies the asset's *stored* crop (`EditorParameters.cropParameters(for:)`) — if
    /// this overlay displayed that directly, reopening "Crop & Straighten…" on a photo that already
    /// has a crop would show the already-cropped result with no way to see (or recover) the parts
    /// trimmed away, rather than the full frame to re-crop from.
    private func loadUncroppedPreview() async {
        var baseParams = rawBaseParameters(for: asset)
        baseParams.crop = nil
        let stageStack = activeStages.map { stageParameters(for: $0, detailEnabled: asset.editDetailEnabled) }
        let renderer = coordinator.renderer
        let image = await Task.detached(priority: .userInitiated) {
            renderer.renderPreview(baseParams: baseParams, stageStack: stageStack, maxPixelSize: 1600)
        }.value
        previewImage = image
    }

    // MARK: - Overlay drawing

    private func scrim(containerSize: CGSize, cropRect: CGRect) -> some View {
        Color.black.opacity(0.55)
            .frame(width: containerSize.width, height: containerSize.height)
            .mask(
                Rectangle()
                    .fill(style: FillStyle(eoFill: true))
                    .overlay(
                        Rectangle()
                            .frame(width: cropRect.width, height: cropRect.height)
                            .position(x: cropRect.midX, y: cropRect.midY)
                            .blendMode(.destinationOut)
                    )
                    .compositingGroup()
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func gridOverlay(in rect: CGRect) -> some View {
        Path { path in
            for fraction in Self.gridLineFractions(gridStyle) {
                let x = rect.minX + fraction * rect.width
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + fraction * rect.height
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            if gridStyle == .diagonals {
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
        }
        .stroke(Color.white.opacity(0.6), lineWidth: 1)
        .allowsHitTesting(false)
    }

    private func handleDots(in rect: CGRect) -> some View {
        ForEach(Array(Self.handlePoints(in: rect).enumerated()), id: \.offset) { _, point in
            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                .position(point)
                .allowsHitTesting(false)
        }
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("Straighten")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: angleBinding, in: -45...45) { Text("Straighten") }
                    .frame(width: 220)
                Text(String(format: "%.1f°", angleDegrees))
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .leading)
                Button("Reset") { angleDegrees = 0; clampCropRectToSafeBounds() }
                    .disabled(angleDegrees == 0)

                Divider().frame(height: 20)

                Text("Aspect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Aspect", selection: $aspectLock) {
                    ForEach(AspectOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .onChange(of: aspectLock) { _, _ in applyAspectLock() }

                Text("Grid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Grid", selection: $gridStyle) {
                    ForEach(GridStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            HStack {
                Text("Drag a handle to resize, drag inside to reposition")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onFinished() }
                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.thinMaterial)
    }

    private var angleBinding: Binding<Double> {
        Binding(
            get: { angleDegrees },
            set: { angleDegrees = $0; clampCropRectToSafeBounds() }
        )
    }

    /// The crop rect's own current pixel aspect (width/height in *pixels*, not normalized) —
    /// `nil` when there's effectively no rect yet (shouldn't happen once `loadGeometry` runs, but
    /// keeps `resized(_:handle:...)` total).
    private var currentAspectRatio: Double? {
        switch aspectLock {
        case .freeform: return nil
        case .original: return imageSize.height > 0 ? imageSize.width / imageSize.height : nil
        default: return aspectLock.ratio
        }
    }

    // MARK: - Aspect lock / safety

    private func applyAspectLock() {
        guard let ratio = currentAspectRatio else { return }
        cropRect = CropTransform.maxCenteredCropRect(angleDegrees: angleDegrees, aspect: ratio, originalSize: imageSize)
    }

    /// Called whenever the straighten angle changes — the safe region shrinks as `|angleDegrees|`
    /// grows, so a crop rect that was fine a moment ago can become unsafe. Re-derives the largest
    /// centered rect at the *same* aspect (locked or, for freeform, the rect's own current aspect)
    /// only when the existing one is no longer safe, so a freeform crop the user carefully
    /// positioned doesn't jump back to centered on every angle tick unless it actually has to.
    private func clampCropRectToSafeBounds() {
        guard !Self.isRectSafe(cropRect, angleDegrees: angleDegrees, originalSize: imageSize, rotatedSize: rotatedSize) else { return }
        let aspect = currentAspectRatio ?? (cropRect.height > 0 ? (cropRect.width * rotatedSize.width) / (cropRect.height * rotatedSize.height) : 1)
        cropRect = CropTransform.maxCenteredCropRect(angleDegrees: angleDegrees, aspect: aspect, originalSize: imageSize)
    }

    // MARK: - Geometry loading / saving

    private func loadGeometry() {
        angleDegrees = asset.editCropAngleDegrees ?? 0
        if let x = asset.editCropRectX, let y = asset.editCropRectY,
           let w = asset.editCropRectWidth, let h = asset.editCropRectHeight {
            cropRect = CGRect(x: x, y: y, width: w, height: h)
        } else {
            cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        aspectLock = .freeform
    }

    private func finish() {
        defer { onFinished() }
        let isIdentity = angleDegrees == 0 && cropRect == CGRect(x: 0, y: 0, width: 1, height: 1)
        if isIdentity {
            resetCrop(asset)
            return
        }
        asset.editCropAngleDegrees = angleDegrees
        asset.editCropRectX = cropRect.minX
        asset.editCropRectY = cropRect.minY
        asset.editCropRectWidth = cropRect.width
        asset.editCropRectHeight = cropRect.height
    }

    // MARK: - Static geometry helpers

    private static func rotatedSize(originalSize: CGSize, angleDegrees: Double) -> CGSize {
        let radians = angleDegrees * .pi / 180
        return CGSize(
            width: originalSize.width * abs(cos(radians)) + originalSize.height * abs(sin(radians)),
            height: originalSize.width * abs(sin(radians)) + originalSize.height * abs(cos(radians))
        )
    }

    private static func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (containerSize.width - fittedSize.width) / 2, y: (containerSize.height - fittedSize.height) / 2)
        return CGRect(origin: origin, size: fittedSize)
    }

    private static func viewRect(for normalized: CGRect, fitRect: CGRect) -> CGRect {
        CGRect(
            x: fitRect.minX + normalized.minX * fitRect.width, y: fitRect.minY + normalized.minY * fitRect.height,
            width: normalized.width * fitRect.width, height: normalized.height * fitRect.height
        )
    }

    private static func handlePoints(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY),
        ]
    }

    private static func nearestHandle(to location: CGPoint, cropRect: CGRect) -> Handle? {
        let candidates: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: cropRect.minX, y: cropRect.minY)),
            (.top, CGPoint(x: cropRect.midX, y: cropRect.minY)),
            (.topRight, CGPoint(x: cropRect.maxX, y: cropRect.minY)),
            (.right, CGPoint(x: cropRect.maxX, y: cropRect.midY)),
            (.bottomRight, CGPoint(x: cropRect.maxX, y: cropRect.maxY)),
            (.bottom, CGPoint(x: cropRect.midX, y: cropRect.maxY)),
            (.bottomLeft, CGPoint(x: cropRect.minX, y: cropRect.maxY)),
            (.left, CGPoint(x: cropRect.minX, y: cropRect.midY)),
        ]
        if let nearest = candidates.min(by: { hypot(location.x - $0.1.x, location.y - $0.1.y) < hypot(location.x - $1.1.x, location.y - $1.1.y) }),
           hypot(location.x - nearest.1.x, location.y - nearest.1.y) <= handleHitRadius {
            return nearest.0
        }
        return cropRect.insetBy(dx: -4, dy: -4).contains(location) ? .move : nil
    }

    /// Resizes/moves `start` by the given normalized drag delta. Corner handles keep the *opposite*
    /// corner fixed (standard crop-tool feel); edge handles move just that edge; `.move` translates
    /// the whole rect. When `aspect` is set, a corner drag is projected onto the fixed corner's
    /// aspect-consistent diagonal instead of following the cursor exactly on both axes.
    private static func resized(_ start: CGRect, handle: Handle, dxNorm: CGFloat, dyNorm: CGFloat, aspect: Double?) -> CGRect {
        switch handle {
        case .move:
            return CGRect(x: start.minX + dxNorm, y: start.minY + dyNorm, width: start.width, height: start.height)
        case .top:
            return CGRect(x: start.minX, y: start.minY + dyNorm, width: start.width, height: start.height - dyNorm)
        case .bottom:
            return CGRect(x: start.minX, y: start.minY, width: start.width, height: start.height + dyNorm)
        case .left:
            return CGRect(x: start.minX + dxNorm, y: start.minY, width: start.width - dxNorm, height: start.height)
        case .right:
            return CGRect(x: start.minX, y: start.minY, width: start.width + dxNorm, height: start.height)
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            return cornerResized(start, handle: handle, dxNorm: dxNorm, dyNorm: dyNorm, aspect: aspect)
        }
    }

    private static func cornerResized(_ start: CGRect, handle: Handle, dxNorm: CGFloat, dyNorm: CGFloat, aspect: Double?) -> CGRect {
        let anchor: CGPoint
        var newCorner: CGPoint
        switch handle {
        case .topLeft:
            anchor = CGPoint(x: start.maxX, y: start.maxY)
            newCorner = CGPoint(x: start.minX + dxNorm, y: start.minY + dyNorm)
        case .topRight:
            anchor = CGPoint(x: start.minX, y: start.maxY)
            newCorner = CGPoint(x: start.maxX + dxNorm, y: start.minY + dyNorm)
        case .bottomRight:
            anchor = CGPoint(x: start.minX, y: start.minY)
            newCorner = CGPoint(x: start.maxX + dxNorm, y: start.maxY + dyNorm)
        case .bottomLeft:
            anchor = CGPoint(x: start.maxX, y: start.minY)
            newCorner = CGPoint(x: start.minX + dxNorm, y: start.maxY + dyNorm)
        default:
            return start
        }
        if let aspect, aspect > 0 {
            let dx = newCorner.x - anchor.x
            let dy = newCorner.y - anchor.y
            // Project onto the aspect-consistent diagonal from the anchor, preserving the drag's
            // dominant axis and sign so the rect grows/shrinks in the direction actually dragged.
            let width = max(abs(dx), abs(dy) * aspect)
            let height = width / aspect
            newCorner = CGPoint(
                x: anchor.x + (dx < 0 ? -width : width),
                y: anchor.y + (dy < 0 ? -height : height)
            )
        }
        return CGRect(
            x: min(anchor.x, newCorner.x), y: min(anchor.y, newCorner.y),
            width: abs(newCorner.x - anchor.x), height: abs(newCorner.y - anchor.y)
        )
    }

    /// Every corner of `rect` (normalized, rotated-frame) must map, under the inverse rotation, back
    /// within the original unrotated image's own bounds — see `CropTransform.maxCenteredCropRect`'s
    /// doc comment for the identical reasoning applied there via bisection instead of a direct check.
    private static func isRectSafe(_ rect: CGRect, angleDegrees: Double, originalSize: CGSize, rotatedSize: CGSize) -> Bool {
        guard rect.width > 0.01, rect.height > 0.01, rect.minX >= -0.0001, rect.minY >= -0.0001,
              rect.maxX <= 1.0001, rect.maxY <= 1.0001 else { return false }
        let radians = angleDegrees * .pi / 180
        let cosA = cos(-radians), sinA = sin(-radians)
        let halfOrigW = originalSize.width / 2, halfOrigH = originalSize.height / 2
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ]
        for corner in corners {
            let px = (corner.x - 0.5) * rotatedSize.width
            let py = (corner.y - 0.5) * rotatedSize.height
            let rx = px * cosA - py * sinA
            let ry = px * sinA + py * cosA
            if abs(rx) > halfOrigW + 0.5 || abs(ry) > halfOrigH + 0.5 { return false }
        }
        return true
    }

    private static func gridLineFractions(_ style: GridStyle) -> [CGFloat] {
        switch style {
        case .none, .diagonals: return []
        case .thirds: return [1.0 / 3, 2.0 / 3]
        case .grid: return [0.25, 0.5, 0.75]
        case .goldenRatio: return [1 - 0.618, 0.618]
        }
    }
}
