import SwiftUI
import PhotoCatalog

/// A compact, VSCode-Source-Control-Graph-style rendering of a photo's saved versions: one row
/// per checkpoint, newest at top, connected by a lane graph so branches (`AssetVersion.branchName`/
/// `.parent`) are visually legible instead of just a flat dated list. Tapping any row checks it
/// out (restores it and moves "current"); it doesn't have to be a branch tip — same as `git
/// checkout <commit>`, not just `git checkout <branch>`.
///
/// A single custom-drawn surface (one `Canvas` for every connector + dot, one `VStack` of plain
/// row content laid over it at matching heights) rather than per-row drawing in a `List` — a
/// connector between two rows needs to be drawn once as a single curve regardless of how many
/// *other* branches' rows fall chronologically between them, which independently-hit-tested `List`
/// rows can't express cleanly.
struct VersionTreeView: View {
    let versions: [AssetVersion]
    let currentVersionID: UUID?
    var onSelect: (AssetVersion) -> Void
    var onNewBranch: (AssetVersion) -> Void
    var onRename: (AssetVersion) -> Void
    var onDelete: (AssetVersion) -> Void

    private let rowHeight: CGFloat = 34
    private let laneWidth: CGFloat = 14
    private let dotRadius: CGFloat = 4

    private var nodes: [VersionGraphNode] {
        VersionGraphLayout.layout(versions)
    }

    private var gutterWidth: CGFloat {
        let laneCount = max(1, (nodes.map(\.lane).max() ?? 0) + 1)
        return CGFloat(laneCount) * laneWidth
    }

    var body: some View {
        let laidOut = nodes
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                draw(laidOut, into: &context)
            }
            .frame(width: gutterWidth, height: CGFloat(laidOut.count) * rowHeight)

            VStack(spacing: 0) {
                ForEach(laidOut) { node in
                    row(for: node)
                        .frame(height: rowHeight)
                }
            }
            .padding(.leading, gutterWidth + 8)
        }
        .frame(height: CGFloat(laidOut.count) * rowHeight)
    }

    private func point(lane: Int, row: Int) -> CGPoint {
        CGPoint(x: CGFloat(lane) * laneWidth + laneWidth / 2, y: CGFloat(row) * rowHeight + rowHeight / 2)
    }

    private func draw(_ nodes: [VersionGraphNode], into context: inout GraphicsContext) {
        // Connectors first, so the dots draw on top of the lines feeding into them.
        for node in nodes {
            guard let parentRowIndex = node.parentRowIndex, nodes.indices.contains(parentRowIndex) else { continue }
            let parent = nodes[parentRowIndex]
            let start = point(lane: node.lane, row: node.rowIndex)
            let end = point(lane: parent.lane, row: parent.rowIndex)
            var path = Path()
            path.move(to: start)
            if node.lane == parent.lane {
                path.addLine(to: end)
            } else {
                // A fork point: this version's branch differs from its parent's — curve from the
                // child's lane over into the parent's, same shape a git graph draws where a branch
                // peels off its source commit.
                let midY = (start.y + end.y) / 2
                path.addCurve(to: end, control1: CGPoint(x: start.x, y: midY), control2: CGPoint(x: end.x, y: midY))
            }
            context.stroke(path, with: .color(Color.versionBranch(node.version.branchName).opacity(0.7)), lineWidth: 1.5)
        }
        for node in nodes {
            let center = point(lane: node.lane, row: node.rowIndex)
            let color = Color.versionBranch(node.version.branchName)
            let dotRect = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
            if node.version.id == currentVersionID {
                let ringRect = dotRect.insetBy(dx: -3, dy: -3)
                context.stroke(Path(ellipseIn: ringRect), with: .color(color), lineWidth: 1.5)
            }
            context.fill(Path(ellipseIn: dotRect), with: .color(color))
        }
    }

    private func row(for node: VersionGraphNode) -> some View {
        let version = node.version
        return Button {
            onSelect(version)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(version.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if version.id == currentVersionID {
                            Text("current")
                                .font(.caption2)
                                .foregroundStyle(Color.versionBranch(version.branchName))
                        }
                    }
                    Text("\(version.branchName) · \(version.createdDate.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("New Branch from Here…") { onNewBranch(version) }
            Button("Rename…") { onRename(version) }
            Button("Delete", role: .destructive) { onDelete(version) }
        }
    }
}
