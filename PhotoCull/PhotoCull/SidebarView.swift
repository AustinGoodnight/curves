import SwiftUI
import PhotoCatalog

struct SidebarView: View, Equatable {
    let sessions: [Session]
    let scenes: [PhotoScene]
    @Binding var selectedSession: Session?
    @Binding var selectedScene: PhotoScene?
    var onNewScene: (Session) -> Void
    var onDeleteScene: (PhotoScene) -> Void
    @Environment(ColorSchemeStore.self) private var uiColors

    static func == (lhs: SidebarView, rhs: SidebarView) -> Bool {
        lhs.sessions == rhs.sessions && lhs.scenes == rhs.scenes
            && lhs.selectedSession == rhs.selectedSession && lhs.selectedScene == rhs.selectedScene
    }

    var body: some View {
        List {
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
                } header: {
                    Button {
                        selectedScene = nil
                        selectedSession = session
                    } label: {
                        Text(session.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .background(isSessionSelected ? uiColors.accentColor.opacity(0.2) : Color.clear)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(uiColors.sidebarBackground)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? uiColors.accentColor.opacity(0.2) : Color.clear)
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
