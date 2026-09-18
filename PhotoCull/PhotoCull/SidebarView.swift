import SwiftUI
import PhotoCatalog

struct SidebarView: View, Equatable {
    let sessions: [Session]
    let scenes: [PhotoScene]
    @Binding var selectedSession: Session?
    @Binding var selectedScene: PhotoScene?
    var onNewScene: (Session) -> Void
    var onDeleteScene: (PhotoScene) -> Void
    var onImportFolder: () -> Void
    @Environment(ColorSchemeStore.self) private var uiColors

    static func == (lhs: SidebarView, rhs: SidebarView) -> Bool {
        lhs.sessions == rhs.sessions && lhs.scenes == rhs.scenes
            && lhs.selectedSession == rhs.selectedSession && lhs.selectedScene == rhs.selectedScene
    }

    var body: some View {
        List {
            Section {
                ForEach(sessions) { session in
                    let isSessionSelected = selectedScene == nil && selectedSession?.id == session.id
                    Section {
                        let scenesInSession = scenesFor(session)
                        ForEach(Array(scenesInSession.enumerated()), id: \.element.id) { index, scene in
                            sceneRow(scene, isLast: index == scenesInSession.count - 1, isSelected: selectedScene?.id == scene.id) {
                                selectedSession = session
                                selectedScene = scene
                            }
                            .contextMenu {
                                Button("Delete Scene", role: .destructive) {
                                    onDeleteScene(scene)
                                }
                            }
                        }
                        Button {
                            onNewScene(session)
                        } label: {
                            Label("New Scene…", systemImage: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                    } header: {
                        sessionHeader(session, isSelected: isSessionSelected)
                    }
                }
            } header: {
                // A plain group label ("SESSIONS"), not a session's own name — distinguishes "this
                // is the list of sessions" from "this session is currently selected" (the latter is
                // `sessionHeader`'s job, one level down). Small-caps/secondary, same convention as
                // every other macOS sidebar's top-level group label (Finder's "Favorites", Mail's
                // "Mailboxes"). The import button rides beside it rather than down with the
                // per-session "New Scene…" rows — importing adds a whole new session/folder, so it
                // belongs at the same level as the group label, not nested under any one session.
                HStack {
                    Text("Sessions")
                    Spacer()
                    Button(action: onImportFolder) {
                        Label("Import", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Import a folder of photos")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(uiColors.sidebarBackground)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
    }

    /// A session's own row/header — distinct from the plain "Sessions" group label above it. The
    /// selected state used to be a full-bleed, edge-to-edge `accentColor.opacity(0.2)` rectangle,
    /// which read as a muddy smear rather than a selection indicator once `accentColor` was a
    /// user-customized non-neutral hue (this app lets it be any color, not just macOS blue) —
    /// same complaint the grid's selection stroke had before it moved to a fixed white
    /// (`PhotoThumbnailCell`). This is a rounded, inset pill in a neutral white tint instead: it
    /// reads as "selected" regardless of what `accentColor` happens to be, and doesn't touch the
    /// row's edges the way `.listRowBackground` (a plain rectangle) would.
    private func sessionHeader(_ session: Session, isSelected: Bool) -> some View {
        Button {
            selectedScene = nil
            selectedSession = session
        } label: {
            Text(session.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.white.opacity(0.16) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .textCase(nil)
    }

    private func scenesFor(_ session: Session) -> [PhotoScene] {
        scenes.filter { $0.session?.id == session.id }
    }

    /// A scene row, shown hanging off its session like a file tree's children — a vertical trunk
    /// down the leading edge with a horizontal stub branching out to the label, in place of the
    /// old flat `rectangle.stack` icon. `isLast` shortens the trunk to a corner (└) instead of a
    /// tee (├) for the final scene in the session, matching how every file-tree UI (Finder's list
    /// view, Xcode's project navigator via indentation guides) terminates a branch.
    private func sceneRow(_ scene: PhotoScene, isLast: Bool, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                TreeConnector(isLast: isLast)
                    .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1))
                    .frame(width: 14)
                Text(scene.name)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.white.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A plain rounded fill inside the row's own content, not `.listRowBackground` — that draws
        // a flat, edge-to-edge rectangle behind the *whole* row (same "muddy full-bleed" shape
        // `sessionHeader`'s doc comment explains moving away from), which would fight visually with
        // this row's own rounded/inset pill.
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
    }
}

/// The vertical trunk + horizontal branch stub `sceneRow` draws in place of a symbol icon — sized
/// to whatever row height the `List` gives it (no fixed height here), so it always spans the full
/// row regardless of font/dynamic-type size. `isLast` stops the trunk at the row's vertical center
/// instead of running it to the bottom, since a final child has nothing below it to connect to.
private struct TreeConnector: Shape {
    var isLast: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let trunkX = rect.minX
        let midY = rect.midY
        path.move(to: CGPoint(x: trunkX, y: rect.minY))
        path.addLine(to: CGPoint(x: trunkX, y: isLast ? midY : rect.maxY))
        path.move(to: CGPoint(x: trunkX, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        return path
    }
}
