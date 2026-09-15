import Foundation
import PhotoCatalog

/// Builds and writes `asset`'s `.curve` sidecar, plus its scene/stack's `.scene`/`.stack` manifest
/// if it belongs to one. The one shared implementation behind both `EditHistory`'s debounced
/// value-edit write (`EditHistory.writeSidecars(for:)` calls straight through to this) and every
/// *structural* mutation site — stage add/delete/rename, version save/restore, rating/flag/color
/// label, scene/stack membership changes — which write immediately rather than waiting on
/// `EditHistory`'s 400ms settle, matching how those sites already bypass it for undo-history
/// purposes (`scheduleRender(..., history: nil)`).
@MainActor
func persistSidecars(for asset: PhotoAsset) {
    let curve = CurveSidecar(capturing: asset)
    let curveURL = asset.sidecarURL()
    Task { await SidecarWriter.shared.write(curve, to: curveURL) }

    if let scene = asset.scene, let session = asset.session {
        persistSidecar(for: scene, session: session)
    }
    if let stack = asset.stack, let session = asset.session {
        persistSidecar(for: stack, session: session)
    }
}

@MainActor
func persistSidecars(for assets: some Sequence<PhotoAsset>) {
    for asset in assets { persistSidecars(for: asset) }
}

@MainActor
func persistSidecar(for scene: PhotoScene, session: Session) {
    let sidecar = SceneSidecar(capturing: scene)
    let url = session.sceneManifestURL(sceneID: scene.id)
    Task { await SidecarWriter.shared.write(sidecar, to: url) }
}

@MainActor
func persistSidecar(for stack: PhotoStack, session: Session) {
    let sidecar = StackSidecar(capturing: stack)
    let url = session.stackManifestURL(stackID: stack.id)
    Task { await SidecarWriter.shared.write(sidecar, to: url) }
}

/// Deletes a scene/stack's manifest file from disk — callers must capture `session` (and, for
/// scenes, the member list they still need to update) *before* calling `modelContext.delete(...)`
/// on the row: a `.nullify` delete rule clears `photos`/`session` the instant the row is deleted, so
/// anything read from the model after that point is already gone.
@MainActor
func deleteSidecarManifest(for scene: PhotoScene, session: Session) {
    try? FileManager.default.removeItem(at: session.sceneManifestURL(sceneID: scene.id))
}

@MainActor
func deleteSidecarManifest(for stack: PhotoStack, session: Session) {
    try? FileManager.default.removeItem(at: session.stackManifestURL(stackID: stack.id))
}
