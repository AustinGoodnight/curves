import Foundation
import PhotoCatalog
import SwiftData

// MARK: - Asset-level fields (exposure / white balance)

extension Preset {
    /// Copies `asset`'s exposure (always — every preset carries exposure) and, when
    /// `includeWhiteBalance` is set, its Temp/Tint and WB bypass switch. See `Preset`'s doc comment
    /// for why these live on the preset itself rather than inside `snapshotData`.
    func captureAssetFields(from asset: PhotoAsset, includeWhiteBalance: Bool) {
        includesExposure = true
        exposure = asset.editExposure
        includesWhiteBalance = includeWhiteBalance
        if includeWhiteBalance {
            neutralTemperature = asset.editNeutralTemperature
            neutralTint = asset.editNeutralTint
            whiteBalanceEnabled = asset.editWhiteBalanceEnabled
        }
    }

    /// Writes whichever asset-level fields this preset carries onto `asset`. A no-op for presets
    /// saved before exposure/WB were captured (both flags `false`).
    func applyAssetFields(to asset: PhotoAsset) {
        if includesExposure {
            asset.editExposure = exposure
        }
        if includesWhiteBalance {
            asset.editNeutralTemperature = neutralTemperature
            asset.editNeutralTint = neutralTint
            asset.editWhiteBalanceEnabled = whiteBalanceEnabled
        }
    }

    var isSessionScoped: Bool { sessionID != nil }
}

// MARK: - On-disk backup

/// A JSON mirror of every `Preset`/`PresetFolder` at `~/Library/Application Support/PhotoCull/
/// presets.json`. Presets aren't photo edits, so they have no sidecar file next to any image —
/// without this, the store-reset path in `PhotoCullApp` (which moves an incompatible store aside
/// and rebuilds from sidecars, see `CacheRebuilder`) would silently lose every preset. Same shape
/// and location as `KnownSessionFolders`: rewritten in full after every preset mutation
/// (`PresetBackup.write(context:)`), read back only when the store has no presets at all.
///
/// Session-scoped presets are backed up like any other — they reference their session by id only
/// (`Preset.sessionID`), so they outlive the session itself.
enum PresetBackup {
    private struct Entry: Codable {
        var id: UUID
        var name: String
        var createdDate: Date
        var snapshotData: Data
        var isDefault: Bool
        var includesExposure: Bool
        var exposure: Double?
        var includesWhiteBalance: Bool
        var neutralTemperature: Double?
        var neutralTint: Double?
        var whiteBalanceEnabled: Bool
        var sessionID: UUID?
        var sessionName: String
        var folderID: UUID?
    }

    private struct FolderEntry: Codable {
        var id: UUID
        var name: String
        var createdDate: Date
    }

    private struct File: Codable {
        var folders: [FolderEntry]
        var presets: [Entry]
    }

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("PhotoCull", isDirectory: true).appendingPathComponent("presets.json")
    }

    /// Saves `context` first so the fetch below reflects just-made inserts *and* deletes, then
    /// rewrites the backup file from scratch. Call after every preset/folder mutation.
    @MainActor
    static func write(context: ModelContext) {
        try? context.save()
        let presets = (try? context.fetch(FetchDescriptor<Preset>())) ?? []
        let folders = (try? context.fetch(FetchDescriptor<PresetFolder>())) ?? []
        let file = File(
            folders: folders.map { FolderEntry(id: $0.id, name: $0.name, createdDate: $0.createdDate) },
            presets: presets.map {
                Entry(
                    id: $0.id, name: $0.name, createdDate: $0.createdDate, snapshotData: $0.snapshotData,
                    isDefault: $0.isDefault, includesExposure: $0.includesExposure, exposure: $0.exposure,
                    includesWhiteBalance: $0.includesWhiteBalance, neutralTemperature: $0.neutralTemperature,
                    neutralTint: $0.neutralTint, whiteBalanceEnabled: $0.whiteBalanceEnabled,
                    sessionID: $0.sessionID, sessionName: $0.sessionName, folderID: $0.folder?.id
                )
            }
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Called once at launch from `PhotoCullApp.sharedModelContainer`. When the store holds no
    /// presets or folders at all (a freshly-reset store), repopulates them from the backup file;
    /// otherwise refreshes the backup from the store, so a library that predates this backup gets
    /// one immediately rather than only after its next preset edit. Deleting every preset also
    /// rewrites the backup to empty, so this never resurrects presets the user deliberately removed.
    @MainActor
    static func syncAtLaunch(context: ModelContext) {
        let presetCount = (try? context.fetchCount(FetchDescriptor<Preset>())) ?? 0
        let folderCount = (try? context.fetchCount(FetchDescriptor<PresetFolder>())) ?? 0
        guard presetCount == 0, folderCount == 0 else {
            write(context: context)
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data),
              !file.presets.isEmpty || !file.folders.isEmpty else { return }

        var foldersByID: [UUID: PresetFolder] = [:]
        for entry in file.folders {
            let folder = PresetFolder(name: entry.name)
            folder.id = entry.id
            folder.createdDate = entry.createdDate
            context.insert(folder)
            foldersByID[entry.id] = folder
        }
        for entry in file.presets {
            let preset = Preset(name: entry.name, snapshotData: entry.snapshotData)
            preset.id = entry.id
            preset.createdDate = entry.createdDate
            preset.isDefault = entry.isDefault
            preset.includesExposure = entry.includesExposure
            preset.exposure = entry.exposure
            preset.includesWhiteBalance = entry.includesWhiteBalance
            preset.neutralTemperature = entry.neutralTemperature
            preset.neutralTint = entry.neutralTint
            preset.whiteBalanceEnabled = entry.whiteBalanceEnabled
            preset.sessionID = entry.sessionID
            preset.sessionName = entry.sessionName
            context.insert(preset)
            preset.folder = entry.folderID.flatMap { foldersByID[$0] }
        }
        try? context.save()
    }
}
