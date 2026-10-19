import Foundation
import PhotoCatalog

/// One version placed into `VersionTreeView`'s grid: which row (newest-first, like `git log`),
/// which lane (vertical column — one per branch), and which row its parent landed on (`nil` for
/// the very first version on the asset).
struct VersionGraphNode: Identifiable {
    let version: AssetVersion
    var id: UUID { version.id }
    var rowIndex: Int
    var lane: Int
    var parentRowIndex: Int?
}

/// Turns a flat `[AssetVersion]` into a row/lane layout for `VersionTreeView` to draw. Lane
/// assignment is deliberately simple — first-seen-wins, never recycled — rather than a
/// general-purpose git-graph packer: a single photo's edit history realistically has a handful of
/// branches, not hundreds, so there's no real column-crowding problem to solve by reusing lanes
/// once a branch ends.
enum VersionGraphLayout {
    static func layout(_ versions: [AssetVersion]) -> [VersionGraphNode] {
        let sorted = versions.sorted { $0.createdDate > $1.createdDate }
        var rowIndexForID: [UUID: Int] = [:]
        for (index, version) in sorted.enumerated() {
            rowIndexForID[version.id] = index
        }

        var laneForBranch: [String: Int] = [:]
        var nextLane = 0
        return sorted.enumerated().map { index, version in
            let lane: Int
            if let existing = laneForBranch[version.branchName] {
                lane = existing
            } else {
                lane = nextLane
                nextLane += 1
                laneForBranch[version.branchName] = lane
            }
            let parentRowIndex = version.parent.flatMap { rowIndexForID[$0.id] }
            return VersionGraphNode(version: version, rowIndex: index, lane: lane, parentRowIndex: parentRowIndex)
        }
    }
}
