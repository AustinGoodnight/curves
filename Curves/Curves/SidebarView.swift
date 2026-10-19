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
    /// Which sessions are collapsed (scenes hidden) — absent means expanded, so a freshly-imported
    /// session starts open without needing an explicit entry here. Plain view-local `@State`, not
    /// `DetailStore`: nothing outside this view needs to know or react to it.
    @State private var collapsedSessionIDs: Set<UUID> = []

    static func == (lhs: SidebarView, rhs: SidebarView) -> Bool {
        lhs.sessions == rhs.sessions && lhs.scenes == rhs.scenes
            && lhs.selectedSession == rhs.selectedSession && lhs.selectedScene == rhs.selectedScene
    }

    var body: some View {
        List {
            // A plain top-level row, not a `Section` header wrapping every session — macOS's
            // `.sidebar` List style only gives a real, independently-clickable disclosure triangle
            // to *top-level* `Section(isExpanded:)`s, one level deep. Nesting every session's own
            // collapsible `Section` inside one more outer "Sessions" `Section` (the first version of
            // this) demoted each session's triangle to a non-interactive stub — confirmed via
            // accessibility inspection (`AXDisclosing` only toggled correctly on the outermost
            // Section). Keeping sessions as the List's own top-level Sections, with this label as an
            // ordinary sibling row above them, is what keeps their triangles real.
            sessionsHeader
                .listRowSeparator(.hidden)
            ForEach(sessions) { session in
                sessionSection(session)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(uiColors.sidebarBackground)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
    }

    /// A plain group label ("SESSIONS"), not a session's own name — distinguishes "this is the
    /// list of sessions" from "this session is currently selected" (the latter is `sessionHeader`'s
    /// job, one level down). Small-caps/secondary, same convention as every other macOS sidebar's
    /// top-level group label (Finder's "Favorites", Mail's "Mailboxes"). The import button rides
    /// beside it rather than down with the per-session "New Scene…" rows — importing adds a whole
    /// new session/folder, so it belongs at the same level as the group label, not nested under
    /// any one session. Pulled out of `body` (along with `sessionSection` below) because the
    /// combined expression was too much for the type-checker to solve in one pass — same "extra
    /// argument in call"/timeout ceiling `ContentView.toolbarContent`'s own doc comment describes.
    private var sessionsHeader: some View {
        HStack(spacing: 0) {
            Text("Sessions")
            Spacer(minLength: 8)
            Button(action: onImportFolder) {
                Label("Import", systemImage: "plus")
                    .font(.caption.weight(.semibold))
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Import a folder of photos")
        }
        // The header's own row insets otherwise clip "Import" flush against the sidebar's
        // trailing edge — every other row gets this breathing room from the List for free, but a
        // `Section` header opts out of it since it's meant to run edge-to-edge.
        .padding(.trailing, 10)
    }

    /// One session's collapsible group of scenes. Deliberately *not* a `Section` at all — any
    /// `Section` header inside a `.sidebar`-style `List` gets macOS's own native disclosure
    /// triangle drawn automatically (hover-revealed, at the row's trailing edge), regardless of
    /// whether `isExpanded:` is used. That's decorative chrome baked into `Section` itself in this
    /// list style, not something wired to our state — it sat right alongside our hand-drawn leading
    /// chevron in `sessionHeader`, showing two chevrons per session. Plain rows (`sessionHeader`
    /// followed by an `if`-gated `ForEach`) carry no such chrome, so our chevron is the only one
    /// that exists.
    @ViewBuilder
    private func sessionSection(_ session: Session) -> some View {
        let isSessionSelected = selectedScene == nil && selectedSession?.id == session.id
        let scenesInSession = scenesFor(session)
        let isExpanded = !collapsedSessionIDs.contains(session.id)
        sessionHeader(session, isSelected: isSessionSelected, isExpanded: isExpanded)
        if isExpanded {
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
        }
    }

    private func toggleCollapsed(_ session: Session) {
        if collapsedSessionIDs.contains(session.id) {
            collapsedSessionIDs.remove(session.id)
        } else {
            collapsedSessionIDs.insert(session.id)
        }
    }

    /// A session's own row/header — distinct from the plain "Sessions" group label above it. The
    /// selected state used to be a full-bleed, edge-to-edge `accentColor.opacity(0.2)` rectangle,
    /// which read as a muddy smear rather than a selection indicator once `accentColor` was a
    /// user-customized non-neutral hue (this app lets it be any color, not just macOS blue) —
    /// same complaint the grid's selection stroke had before it moved to a fixed white
    /// (`PhotoThumbnailCell`). This is a rounded, inset pill in a neutral white tint instead: it
    /// reads as "selected" regardless of what `accentColor` happens to be, and doesn't touch the
    /// row's edges the way `.listRowBackground` (a plain rectangle) would.
    private func sessionHeader(_ session: Session, isSelected: Bool, isExpanded: Bool) -> some View {
        // One row-level tap (selects the session) with a small `.overlay` tap zone over just the
        // chevron — not two separate `Button`s. Two `Button`s in the same plain `List` row fight
        // over the same click on macOS (the row's own selection handling only reliably forwards a
        // tap to *one* child control), which is exactly why the chevron stopped collapsing anything
        // once this became a plain row instead of a `Section` header (headers aren't subject to
        // that same row-click machinery). A single outer tap plus a layered hit-zone sidesteps the
        // conflict entirely: whichever region the tap lands in is the only gesture that fires.
        HStack(spacing: 2) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 14, height: 14)

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
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedScene = nil
            selectedSession = session
        }
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 20)
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleCollapsed(session)
                }
        }
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
