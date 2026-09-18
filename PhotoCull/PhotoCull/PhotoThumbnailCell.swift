import SwiftUI
import PhotoCatalog

enum StackBadge {
    case collapsed(count: Int)
    case expandedMember(position: Int, total: Int)
}

/// A stable, distinguishable-at-a-glance color per scene without needing a stored/user-picked
/// color field — picked deterministically from `scene.id`'s raw bytes, not `UUID.hashValue`:
/// Swift's `Hashable` uses a per-process-random seed by design, so `hashValue` for the same
/// `UUID` differs across launches and would make a scene's color flicker between app restarts.
/// Summing the persisted UUID's own bytes instead gives the same index every time. A free
/// function rather than a `PhotoThumbnailCell` method since `CullingGridView` needs it too, to
/// build the `SceneBorderInfo` it passes down.
func sceneBorderColor(for scene: PhotoScene) -> Color {
    let palette: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown]
    let bytes = scene.id.uuid
    let sum = withUnsafeBytes(of: bytes) { raw in raw.reduce(0) { $0 + Int($1) } }
    return palette[sum % palette.count]
}

/// A scene's photo gets a colored mat behind it (see `PhotoThumbnailCell.body`/`SceneMatShape`)
/// plus, on one cell per group, a name label on top. `CullingGridView` computes this per cell —
/// only it knows a cell's scene and its neighbors — `PhotoThumbnailCell` just draws whatever it's
/// told.
struct SceneBorderInfo {
    /// How `SceneMatShape` should draw one corner of a cell's mat, decided from that corner's two
    /// adjacent edges and its diagonal neighbor (all same-scene checks, computed in
    /// `CullingGridView.sceneBorderInfo`):
    /// - `.convex`: neither adjacent edge continues into a same-scene neighbor — a true outer
    ///   corner of the group, rounded outward like an ordinary rounded rect corner.
    /// - `.concave`: *both* adjacent edges continue, but the diagonal neighbor is a *different*
    ///   scene (or none) — an inner corner where an irregular block bends, rounded *inward* instead
    ///   (a "liquid" notch) so the joint between the two arms reads as one smoothly-flowing shape
    ///   rather than a sharp reflex angle.
    /// - `.square`: everything else — either exactly one adjacent edge continues (a corner sitting
    ///   midway along an otherwise-straight run), or both do and the diagonal neighbor also matches
    ///   (a corner fully interior to a solid block, needing no visual treatment at all).
    enum CornerKind {
        case convex
        case concave
        case square
    }

    var color: Color
    /// Non-nil only on the group's top-right corner cell (see `CullingGridView.sceneBorderInfo`)
    /// — shown once per group, not once per photo.
    var name: String?
    var topLeading: CornerKind
    var topTrailing: CornerKind
    var bottomLeading: CornerKind
    var bottomTrailing: CornerKind
    /// Whether each edge borders a same-scene neighbor — `PhotoThumbnailCell` extends the mat by
    /// half `CullingGridView`'s inter-cell spacing into the gutter on any `true` edge (matching the
    /// old wrapping-outline's own gutter-extension trick) so two adjacent cells' mats meet exactly
    /// in the middle with no visible gap.
    var topMerged: Bool
    var bottomMerged: Bool
    var leadingMerged: Bool
    var trailingMerged: Bool
}

/// The filled shape `PhotoThumbnailCell`'s scene mat is drawn with — a `RoundedRectangle` with each
/// of its 4 corners independently convex, concave, or square (see `SceneBorderInfo.CornerKind`).
/// Traces the rect clockwise (top edge → top-trailing corner → trailing edge → …), building each
/// corner from its own two tangent points (`r` in from the true corner along each adjacent edge)
/// plus, for `.concave`, the true corner point itself: a convex corner arcs around a center inset
/// by `r` from both edges (the usual rounded-rect construction); a concave corner arcs around a
/// center placed *at the true corner* instead, tracing the same two tangent points but curving the
/// other way, which is what carves the inward notch.
private struct SceneMatShape: Shape {
    var topLeading: SceneBorderInfo.CornerKind
    var topTrailing: SceneBorderInfo.CornerKind
    var bottomLeading: SceneBorderInfo.CornerKind
    var bottomTrailing: SceneBorderInfo.CornerKind
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        let minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY

        let tlCorner = CGPoint(x: minX, y: minY)
        let tlOnTop = CGPoint(x: minX + r, y: minY)
        let tlOnLeading = CGPoint(x: minX, y: minY + r)

        let trCorner = CGPoint(x: maxX, y: minY)
        let trOnTop = CGPoint(x: maxX - r, y: minY)
        let trOnTrailing = CGPoint(x: maxX, y: minY + r)

        let brCorner = CGPoint(x: maxX, y: maxY)
        let brOnTrailing = CGPoint(x: maxX, y: maxY - r)
        let brOnBottom = CGPoint(x: maxX - r, y: maxY)

        let blCorner = CGPoint(x: minX, y: maxY)
        let blOnBottom = CGPoint(x: minX + r, y: maxY)
        let blOnLeading = CGPoint(x: minX, y: maxY - r)

        var path = Path()
        path.move(to: topLeading == .square ? tlCorner : tlOnTop)

        path.addLine(to: topTrailing == .square ? trCorner : trOnTop)
        addCorner(&path, topTrailing, corner: trCorner, from: trOnTop, to: trOnTrailing, insetCenter: CGPoint(x: maxX - r, y: minY + r))

        path.addLine(to: bottomTrailing == .square ? brCorner : brOnTrailing)
        addCorner(&path, bottomTrailing, corner: brCorner, from: brOnTrailing, to: brOnBottom, insetCenter: CGPoint(x: maxX - r, y: maxY - r))

        path.addLine(to: bottomLeading == .square ? blCorner : blOnBottom)
        addCorner(&path, bottomLeading, corner: blCorner, from: blOnBottom, to: blOnLeading, insetCenter: CGPoint(x: minX + r, y: maxY - r))

        path.addLine(to: topLeading == .square ? tlCorner : tlOnLeading)
        addCorner(&path, topLeading, corner: tlCorner, from: tlOnLeading, to: tlOnTop, insetCenter: CGPoint(x: minX + r, y: minY + r))

        path.closeSubpath()
        return path
    }

    private func addCorner(
        _ path: inout Path, _ kind: SceneBorderInfo.CornerKind, corner: CGPoint, from: CGPoint, to: CGPoint,
        insetCenter: CGPoint
    ) {
        switch kind {
        case .square:
            break
        case .convex:
            path.addArc(
                center: insetCenter, radius: radius,
                startAngle: angle(from: insetCenter, to: from), endAngle: angle(from: insetCenter, to: to),
                clockwise: false
            )
        case .concave:
            path.addArc(
                center: corner, radius: radius,
                startAngle: angle(from: corner, to: from), endAngle: angle(from: corner, to: to),
                clockwise: true
            )
        }
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> Angle {
        .radians(Double(atan2(point.y - center.y, point.x - center.x)))
    }
}

struct PhotoThumbnailCell: View {
    @Bindable var asset: PhotoAsset
    let isSelected: Bool
    var stackBadge: StackBadge? = nil
    var onToggleStack: (() -> Void)? = nil
    /// The grid's current column count (`DetailStore.gridColumnCount`) — used only to scale this
    /// cell's fixed height so it stays proportional to the flexible `GridItem` width `CullingGridView`
    /// gives each column. Without this, zooming the grid (fewer/more columns) changed cell *width*
    /// only, since `.frame(height:)` below was a bare constant: cells got wider but not taller, which
    /// read as the photo's mat growing while the photo itself stayed the same size inside it — not
    /// what "zoom" should look like. `CullingGridView` already knows the current column count (it's
    /// how it lays out `gridColumns`), so this is just threaded down rather than measured here.
    var columnCount: Int = 7
    var sceneBorder: SceneBorderInfo? = nil
    var onOpenEditor: (() -> Void)? = nil

    @State private var thumbnail: CGImage?
    @State private var isHovering = false
    @Environment(ColorSchemeStore.self) private var uiColors

    /// 140pt at the default 7-column grid, scaled inversely with `columnCount` so a cell's height
    /// grows/shrinks in lockstep with its `GridItem`-driven width — plain O(1) arithmetic, not a
    /// measurement, so it's safe to read directly here despite the CLAUDE.md rule against reading
    /// expensive computed properties in `body` (that rule is about O(n) scans, not this).
    private var thumbnailHeight: CGFloat {
        140 * 7 / CGFloat(columnCount)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // The scene's color as a mat *behind* the photo — not a stroke on top of it or a
                // badge floating over a corner. The photo (below) insets a few pt from this shape's
                // own edges, so the color shows as a uniform margin all the way around it, like a
                // mat behind a framed print. Extended into the gutter on any merged edge (see
                // `SceneBorderInfo.topMerged`'s doc comment) so a same-scene neighbor's own mat
                // meets this one with no gap — `SceneMatShape`'s per-corner convex/concave/square
                // treatment is what then makes that joined shape read as one smooth, "liquid" region
                // instead of a grid of separate square swatches. Dimmed via opacity, not a manually-
                // desaturated color — the palette in `sceneBorderColor(for:)` is picked at full
                // saturation so it still reads clearly at the name label's small pill size (see
                // below), which stays at full opacity.
                if let sceneBorder {
                    SceneMatShape(
                        topLeading: sceneBorder.topLeading, topTrailing: sceneBorder.topTrailing,
                        bottomLeading: sceneBorder.bottomLeading, bottomTrailing: sceneBorder.bottomTrailing,
                        radius: 8
                    )
                    .fill(sceneBorder.color.opacity(0.45))
                    .padding(EdgeInsets(
                        top: sceneBorder.topMerged ? -6 : 0,
                        leading: sceneBorder.leadingMerged ? -6 : 0,
                        bottom: sceneBorder.bottomMerged ? -6 : 0,
                        trailing: sceneBorder.trailingMerged ? -6 : 0
                    ))
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.gray.opacity(0.15))
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if asset.flag == .reject {
                        Color.black.opacity(0.35)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(sceneBorder == nil ? 0 : 5)
            }
            .frame(height: thumbnailHeight)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? uiColors.accentColor : .clear, lineWidth: 3)
            )
            .overlay(alignment: .topTrailing) { flagBadge }
            .overlay(alignment: .topLeading) { colorDot }
            .overlay(alignment: .bottomLeading) { stackBadgeView }
            .overlay(alignment: .topLeading) { sceneNameLabel }
            .overlay(alignment: .topTrailing) { editButton }
            .onHover { isHovering = $0 }

            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= asset.rating ? "star.fill" : "star")
                        .font(.caption2)
                        .foregroundStyle(star <= asset.rating ? .yellow : .secondary)
                }
            }

            Text(asset.fileName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .task(id: "\(asset.filePath)#\(ThumbnailInvalidationBus.shared.box(for: asset.filePath).value)") {
            await loadThumbnail()
        }
    }

    @ViewBuilder private var flagBadge: some View {
        switch asset.flag {
        case .pick:
            Image(systemName: "flag.fill")
                .foregroundStyle(.green)
                .padding(4)
                .background(.thinMaterial, in: Circle())
                .padding(4)
        case .reject:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .padding(4)
                .background(.thinMaterial, in: Circle())
                .padding(4)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var colorDot: some View {
        if asset.colorLabel != .none {
            Circle()
                .fill(color(for: asset.colorLabel))
                .frame(width: 10, height: 10)
                .padding(6)
        }
    }

    @ViewBuilder private var stackBadgeView: some View {
        switch stackBadge {
        case .collapsed(let count):
            Button(action: { onToggleStack?() }) {
                HStack(spacing: 3) {
                    Image(systemName: "square.stack")
                    Text("\(count)")
                }
            }
            .buttonStyle(.plain)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .padding(4)
        case .expandedMember(let position, let total):
            HStack(spacing: 3) {
                if position == 1 {
                    Button(action: { onToggleStack?() }) {
                        Image(systemName: "chevron.down.square.fill")
                    }
                    .buttonStyle(.plain)
                }
                Text("\(position)/\(total)")
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .padding(4)
        case nil:
            EmptyView()
        }
    }

    private func color(for label: ColorLabel) -> Color {
        switch label {
        case .none: return .clear
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }

    /// The scene's name, shown once per group (see `SceneBorderInfo.name`) — a filled pill in the
    /// scene's own color, sitting *on top* of the photo (unlike the dimmed mat behind it, so the
    /// pill itself stays at full opacity/legible regardless of what's under it). Top-leading, not
    /// top-trailing — that corner's shared with `editButton`/`flagBadge` instead. Offset below
    /// `colorDot`'s own top-leading spot (a filled circle roughly 22pt tall including its padding)
    /// rather than sharing the exact corner, so the rare case of a color-labeled photo also being a
    /// group's label-holder doesn't overlap the two.
    @ViewBuilder private var sceneNameLabel: some View {
        if let name = sceneBorder?.name {
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(sceneBorder?.color ?? .clear, in: Capsule())
                .padding(.top, 26)
                .padding(.leading, 6)
        }
    }

    /// Opening a photo is this hover-revealed button, never the cell's own click — see
    /// `CullingGridView.cell(for:at:)`'s doc comment for why a click only ever selects now.
    /// Pinned to the top-right corner alongside `flagBadge` (also top-trailing) — offset further
    /// right when a flag badge is actually showing so the two don't overlap.
    @ViewBuilder private var editButton: some View {
        if isHovering, let onOpenEditor {
            Button(action: onOpenEditor) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .padding(.trailing, asset.flag == .none ? 4 : 34)
        }
    }

    private func loadThumbnail() async {
        let key = asset.filePath
        if let cached = ThumbnailCache.shared.image(for: key) {
            thumbnail = cached
            return
        }
        let url = asset.resolvedURL()
        let image = await Task.detached(priority: .userInitiated) {
            ThumbnailProvider.thumbnail(for: url)
        }.value
        if let image {
            ThumbnailCache.shared.setImage(image, for: key)
            thumbnail = image
        }
    }
}
