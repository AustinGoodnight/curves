import SwiftUI
import PhotoCatalog

struct SidebarView: View, Equatable {
    let sessions: [Session]
    let scenes: [PhotoScene]
    @Binding var selectedSession: Session?
    @Binding var selectedScene: PhotoScene?
    var onNewScene: (Session) -> Void
    var onDeleteScene: (PhotoScene) -> Void

    static func == (lhs: SidebarView, rhs: SidebarView) -> Bool {
        lhs.sessions == rhs.sessions && lhs.scenes == rhs.scenes
            && lhs.selectedSession == rhs.selectedSession && lhs.selectedScene == rhs.selectedScene
    }

    var body: some View {
        List {
            ForEach(sessions) { session in
                let isSessionSelected = selectedScene == nil && selectedSession?.id == session.id
                Section {
                    ForEach(scenesFor(session)) { scene in
                        row(title: scene.name, systemImage: "rectangle.stack", isSelected: selectedScene?.id == scene.id) {
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
                    .background(isSessionSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.sidebarBackground)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
    }

    private func scenesFor(_ session: Session) -> [PhotoScene] {
        scenes.filter { $0.session?.id == session.id }
    }

    private func row(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}
