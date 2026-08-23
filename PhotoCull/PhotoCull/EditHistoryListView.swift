import SwiftUI

/// The "History" section's scrollable, running log of every committed edit this session, newest
/// at top — Lightroom's History panel, essentially. Click any row to jump straight there (not just
/// one step at a time like Cmd+Z), same as `VersionTreeView`'s rows.
///
/// A separate `View` type (not inline in `StagesSidebarView.body`) so its own read of
/// `history.entries`/`.currentIndex` — which changes on every settled edit, roughly every ~400ms
/// during a continuous drag — doesn't also force `StagesSidebarView.body` to re-diff the Stages
/// list, Info/EXIF, Versions tree, and Stack list on the same cadence. Same reasoning as
/// `EditorSidebarView`/`ColorBalanceBarView`'s split — see `EditorRenderCoordinator`'s doc comment.
struct EditHistoryListView: View {
    let history: EditHistory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(history.entries.enumerated().reversed()), id: \.element.id) { index, entry in
                    row(index: index, entry: entry)
                }
            }
        }
        .frame(height: 160)
    }

    private func row(index: Int, entry: EditHistory.Entry) -> some View {
        let isCurrent = index == history.currentIndex
        return Button {
            history.jump(to: index)
        } label: {
            HStack(spacing: 6) {
                Text(entry.label)
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isCurrent ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}
