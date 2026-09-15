import Foundation
import PhotoCatalog
import SwiftData

/// Repopulates an empty `ModelContainer` from sidecar files on disk — the actual point of the whole
/// sidecar-persistence design (see this project's CLAUDE.md and `SidecarModels.swift`'s doc
/// comment): a schema break used to mean "start over empty"; this makes it mean "rescan and
/// restore." Run only in two places, deliberately never on a normal successful launch — see
/// `PhotoCullApp.swift`'s `ModelContainer` failure path and `ContentView`'s manual "Rescan" action —
/// since this reads every sidecar in every known folder, which is exactly the kind of cost this
/// codebase's CLAUDE.md warns against paying inside a live, `@Query`-driven view.
@MainActor
enum CacheRebuilder {
    /// One pass per known session folder (see `KnownSessionFolders`): re-imports every image file
    /// found there as a fresh `PhotoAsset`, adopts each one's `.curve` sidecar if present, then
    /// reconstructs `PhotoScene`/`PhotoStack` rows from `.scene`/`.stack` manifests and links their
    /// members. A sidecar that fails to decode is treated as missing, never a crash (see
    /// `SidecarModels.swift`'s doc comment) — a partial or corrupt sidecar loses just that one
    /// photo's edits, not the whole rebuild.
    static func rebuild(context: ModelContext) {
        for folderEntry in KnownSessionFolders.load() {
            rebuildSession(from: folderEntry, context: context)
        }
    }

    private static func rebuildSession(from folderEntry: KnownSessionFolderEntry, context: ModelContext) {
        let folderURL = folderEntry.resolvedURL()
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return }

        let session = Session(name: folderEntry.name, folderURL: folderURL)
        session.id = folderEntry.id
        context.insert(session)

        let importer = LibraryImporter()
        let files = importer.scanFolder(at: folderURL, recursive: true)
        guard let assets = try? importer.importFiles(files, into: context, session: session) else { return }

        // Adopt each asset's own `.curve` — base fields, rating/flag/color label, single stage,
        // version history. Custom stages are handled after scene/stack reconstruction below: a
        // stacked asset's `.curve`.customStages is a redundant copy of its stack's own (authoritative)
        // custom stages, so recreating them here too would duplicate every one of them.
        var curveByAssetID: [UUID: CurveSidecar] = [:]
        for asset in assets {
            guard let data = try? Data(contentsOf: asset.sidecarURL()),
                  let sidecar = try? JSONDecoder().decode(CurveSidecar.self, from: data) else { continue }
            curveByAssetID[asset.id] = sidecar
            sidecar.baseFields.apply(to: asset)
            asset.ratingRaw = sidecar.rating
            asset.flagRaw = sidecar.flagRaw
            asset.colorLabelRaw = sidecar.colorLabelRaw
            sidecar.singleStage.apply(to: asset.singleStage)
            asset.currentVersionID = sidecar.currentVersionID
            restoreVersionHistory(sidecar.versions, to: asset, context: context)
        }

        // Non-recursive: manifests always sit flat at the session folder's root (see
        // `Session.sceneManifestURL(sceneID:)`'s doc comment), regardless of whether "Include
        // Subfolders" pulled member photos from deeper in the tree.
        let manifestFiles = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        for fileURL in manifestFiles where fileURL.pathExtension == "scene" {
            guard let data = try? Data(contentsOf: fileURL),
                  let sidecar = try? JSONDecoder().decode(SceneSidecar.self, from: data) else { continue }
            let scene = PhotoScene(name: sidecar.name, session: session)
            scene.id = sidecar.sceneID
            scene.createdDate = sidecar.createdDate
            context.insert(scene)
            if let stage = scene.stage { sidecar.stage.apply(to: stage) }
            for asset in assets where sidecar.memberFileNames.contains(asset.fileName) {
                asset.scene = scene
            }
        }

        for fileURL in manifestFiles where fileURL.pathExtension == "stack" {
            guard let data = try? Data(contentsOf: fileURL),
                  let sidecar = try? JSONDecoder().decode(StackSidecar.self, from: data) else { continue }
            let stack = PhotoStack(name: sidecar.name)
            stack.id = sidecar.stackID
            stack.createdDate = sidecar.createdDate
            context.insert(stack)
            if let stage = stack.singleStage { sidecar.singleStage.apply(to: stage) }
            for entry in sidecar.customStages {
                let stage = Stage(kind: .custom, name: entry.name, stack: stack, sortIndex: entry.sortIndex)
                context.insert(stage)
                entry.apply(to: stage)
            }
            for asset in assets where sidecar.memberFileNames.contains(asset.fileName) {
                asset.stack = stack
            }
        }

        // Only for assets that ended up *unstacked* — a stacked asset's custom stages already came
        // from the `.stack` manifest above, and its own `.curve`.customStages is just that same data
        // copied for self-sufficiency (see `CurveSidecar.customStages`'s doc comment).
        for asset in assets where asset.stack == nil {
            guard let sidecar = curveByAssetID[asset.id] else { continue }
            for entry in sidecar.customStages {
                let stage = Stage(kind: .custom, name: entry.name, asset: asset, sortIndex: entry.sortIndex)
                context.insert(stage)
                entry.apply(to: stage)
            }
        }

        try? context.save()
    }

    /// Two passes: create every `AssetVersion` row first (unparented), then wire up `parent`
    /// pointers by id — a version can reference a parent that appears later in `entries`' own
    /// array order (it doesn't, in practice, since versions are always appended after their
    /// parent, but nothing in the sidecar format guarantees that ordering survives a hand edit or a
    /// future writer, so this doesn't assume it).
    private static func restoreVersionHistory(_ entries: [VersionEntry], to asset: PhotoAsset, context: ModelContext) {
        guard !entries.isEmpty else { return }
        var rowsByID: [UUID: AssetVersion] = [:]
        for entry in entries {
            guard let data = try? JSONEncoder().encode(AssetVersionSnapshot(wide: entry)) else { continue }
            let row = AssetVersion(name: entry.name, branchName: entry.branchName, asset: asset, parent: nil, snapshotData: data)
            row.id = entry.id
            row.createdDate = entry.createdDate
            context.insert(row)
            rowsByID[entry.id] = row
        }
        for entry in entries {
            guard let parentID = entry.parentID else { continue }
            rowsByID[entry.id]?.parent = rowsByID[parentID]
        }
    }
}
