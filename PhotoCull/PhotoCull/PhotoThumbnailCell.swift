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

/// Which of a cell's 4 edges border a *different* scene (or the grid boundary) versus a same-
/// scene neighbor. `CullingGridView` computes this per cell from its grid position, since only it
/// knows the neighbors — `PhotoThumbnailCell` just draws whatever it's told. A `merged` edge gets
/// no stroke there and the shape extends halfway into the gutter instead, so two adjacent same-
/// scene cells' borders meet in the middle of the gap with no visible seam; a boundary edge gets
/// a stroke and a smaller outward extension, matching the selection ring's own inset. See
/// `SceneBorderShape`/`PhotoThumbnailCell.sceneBorderOverlay` for how the two extension amounts
/// are what actually produces one continuous outline around an irregular block of cells, not
/// separate rings per photo.
struct SceneBorderInfo {
    var color: Color
    /// Non-nil only on the group's top-right corner cell (see `CullingGridView.sceneBorderInfo`)
    /// — shown once per group, not once per photo.
    var name: String?
    var topMerged: Bool
    var bottomMerged: Bool
    var leadingMerged: Bool
    var trailingMerged: Bool
}

/// Draws only the requested edges of a rect — the building block `sceneBorderOverlay` uses to
/// turn per-cell edge decisions into what reads as one wrapping outline. Straight corners rather
/// than `RoundedRectangle`'s rounded ones: a rounded corner only makes sense at the true outer
/// corners of a group, and telling those apart from an inner seam (where two boundary edges of
/// *different*, non-adjacent group corners happen to meet) isn't worth the complexity here.
private struct SceneBorderShape: Shape {
    var top: Bool
    var bottom: Bool
    var leading: Bool
    var trailing: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if top {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        if trailing {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        if bottom {
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        if leading {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        return path
    }
}

struct PhotoThumbnailCell: View {
    @Bindable var asset: PhotoAsset
    let isSelected: Bool
    var stackBadge: StackBadge? = nil
    var onToggleStack: (() -> Void)? = nil
    var sceneBorder: SceneBorderInfo? = nil
    var onOpenEditor: (() -> Void)? = nil

    @State private var thumbnail: CGImage?
    @State private var isHovering = false
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        VStack(spacing: 6) {
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
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { sceneBorderOverlay }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? uiColors.accentColor : .clear, lineWidth: 3)
            )
            .overlay(alignment: .topTrailing) { flagBadge }
            .overlay(alignment: .topLeading) { colorDot }
            .overlay(alignment: .bottomLeading) { stackBadgeView }
            .overlay(alignment: .topTrailing) { sceneNameLabel }
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
        .task(id: asset.filePath) {
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

    /// Boundary edges (facing a different scene, no scene, or the grid edge) get a small 4pt
    /// outward extension — enough to clear the selection ring drawn just inside the frame. Merged
    /// edges (facing a same-scene neighbor) get pulled instead of stroked, and the shape extends
    /// 6pt outward there — half of `CullingGridView`'s 12pt inter-cell spacing — so this cell's
    /// extension meets the neighbor's own 6pt extension exactly in the middle of the gutter
    /// between them, with no gap. A boundary edge that's actually drawn (top/bottom/leading/
    /// trailing when not merged) spans the shape's *full*, already-extended rect — that's what
    /// lets e.g. a top edge continue unbroken across a merged left/right seam instead of stopping
    /// at this cell's own original width.
    @ViewBuilder private var sceneBorderOverlay: some View {
        if let sceneBorder {
            SceneBorderShape(
                top: !sceneBorder.topMerged, bottom: !sceneBorder.bottomMerged,
                leading: !sceneBorder.leadingMerged, trailing: !sceneBorder.trailingMerged
            )
            .stroke(sceneBorder.color, lineWidth: 3)
            .padding(EdgeInsets(
                top: sceneBorder.topMerged ? -6 : -4,
                leading: sceneBorder.leadingMerged ? -6 : -4,
                bottom: sceneBorder.bottomMerged ? -6 : -4,
                trailing: sceneBorder.trailingMerged ? -6 : -4
            ))
        }
    }

    /// The scene's name, shown once per group (see `SceneBorderInfo.name`) just inside the
    /// border's top-right corner. Offset below `flagBadge`'s own top-trailing spot (a filled
    /// circle roughly 24pt tall including its padding) rather than sharing the exact corner, so
    /// the rare case of a rejected/picked photo also being a group's label-holder doesn't overlap
    /// the two.
    @ViewBuilder private var sceneNameLabel: some View {
        if let name = sceneBorder?.name {
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
                .foregroundStyle(sceneBorder?.color ?? .primary)
                .padding(.top, 26)
                .padding(.trailing, 6)
        }
    }

    /// Opening a photo is this hover-revealed button, never the cell's own click — see
    /// `CullingGridView.cell(for:at:)`'s doc comment for why a click only ever selects now.
    /// Pinned to the top-right corner alongside `flagBadge` (also top-trailing) — offset further
    /// right when a flag badge is actually showing so the two don't overlap; `sceneNameLabel`
    /// lives in the same corner too but is pushed down 26pt, well clear of this row.
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
