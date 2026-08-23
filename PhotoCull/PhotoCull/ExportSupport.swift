import Foundation
import AppKit
import PhotoCatalog
import RawEngine

/// A resolved export configuration — what `ExportBarView`'s preset menu actually hands to
/// `performBatchExport`. Built-in presets (`BuiltInExportPresets.all`) are plain values, never
/// persisted; user-created ones are stored as `ExportPreset` (SwiftData) and converted via
/// `ExportPreset.settings` below. Keeping both as this one flat struct means the export bar/batch
/// export code never needs to branch on "built-in vs. custom" past the menu that picks one.
struct ExportSettings: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var format: ExportImageFormat
    var quality: Double
    /// `nil` = full native resolution — see `ExportPreset.maxLongEdge`'s doc comment.
    var maxLongEdge: Double?

    var exportFormat: ExportFormat {
        switch format {
        case .jpeg: return .jpeg(quality: quality)
        case .tiff: return .tiff
        case .png: return .png
        }
    }

    var fileExtension: String {
        switch format {
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .png: return "png"
        }
    }
}

extension ExportPreset {
    var settings: ExportSettings {
        ExportSettings(name: name, format: format, quality: quality, maxLongEdge: maxLongEdge)
    }
}

enum BuiltInExportPresets {
    static let all: [ExportSettings] = [
        ExportSettings(name: "Lossless", format: .tiff, quality: 1, maxLongEdge: nil),
        ExportSettings(name: "90% JPG", format: .jpeg, quality: 0.9, maxLongEdge: nil),
        ExportSettings(name: "80% JPG", format: .jpeg, quality: 0.8, maxLongEdge: nil),
        ExportSettings(name: "Instagram", format: .jpeg, quality: 0.9, maxLongEdge: 1080),
    ]
}

/// Where a batch export writes its files — chosen in `ExportDestinationSheet`. `.nestedInSourceFolder`
/// resolves per-asset (`url(for:)`) rather than to one shared path: a session's photos aren't
/// guaranteed to live in one folder (recursive "Include Subfolders" imports can pull from several),
/// so "inside the session folder" means, precisely, "next to each photo's own original file" —
/// correct for the common single-folder case and still sensible for a multi-folder one.
enum ExportDestination {
    case folder(URL)
    case nestedInSourceFolder(name: String)

    func url(for asset: PhotoAsset) -> URL {
        switch self {
        case .folder(let url):
            return url
        case .nestedInSourceFolder(let name):
            return asset.resolvedURL().deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        }
    }
}

enum ExportScope: Identifiable, Hashable {
    case selection
    case all
    var id: Self { self }
}

/// One asset's worth of work, pre-resolved on the main actor (reads `PhotoAsset`/`Stage` fields,
/// which aren't safe to touch off it) before the batch itself runs on a background task — see
/// `performBatchExport`.
private struct ExportItem {
    let baseParams: RawBaseParameters
    let stageParams: [StageParameters]
    let sourceURL: URL
    let destinationFolder: URL
    let fileName: String
}

/// Renders and writes every asset in `assets` at `settings`'s format/quality/size, to
/// `destination`. Runs the whole loop on one detached background task — each asset gets its own
/// `RawImageRenderer` (per `RawImageRenderer`'s own doc comment: "create a new renderer per image,
/// not per render"), created and discarded entirely inside that task so no SwiftData `@Model`
/// object ever crosses the actor boundary; only the plain value types captured in `ExportItem` do.
/// `onProgress` is hopped back to the main actor for each completed photo so callers can drive a
/// `@State` progress indicator.
@MainActor
func performBatchExport(
    assets: [PhotoAsset],
    settings: ExportSettings,
    destination: ExportDestination,
    onProgress: @escaping (Int, Int) -> Void
) async -> (succeeded: Int, failed: Int) {
    let items = assets.map { asset -> ExportItem in
        let activeStages = activeStageStack(for: asset)
        return ExportItem(
            baseParams: rawBaseParameters(for: asset),
            stageParams: activeStages.map { stageParameters(for: $0, detailEnabled: asset.editDetailEnabled) },
            sourceURL: asset.resolvedURL(),
            destinationFolder: destination.url(for: asset),
            fileName: "\((asset.fileName as NSString).deletingPathExtension).\(settings.fileExtension)"
        )
    }
    let format = settings.exportFormat
    let maxLongEdge = settings.maxLongEdge.map { CGFloat($0) }
    let total = items.count

    return await Task.detached(priority: .userInitiated) {
        var succeeded = 0
        var failed = 0
        for (index, item) in items.enumerated() {
            let renderer = RawImageRenderer()
            var ok = false
            if renderer.load(url: item.sourceURL) {
                do {
                    try FileManager.default.createDirectory(at: item.destinationFolder, withIntermediateDirectories: true)
                    let outputURL = item.destinationFolder.appendingPathComponent(item.fileName)
                    try ExportPipeline.export(
                        renderer: renderer,
                        baseParams: item.baseParams,
                        stageStack: item.stageParams,
                        format: format,
                        maxLongEdge: maxLongEdge,
                        to: outputURL
                    )
                    ok = true
                } catch {
                    ok = false
                }
            }
            if ok { succeeded += 1 } else { failed += 1 }
            let completed = index + 1
            await MainActor.run { onProgress(completed, total) }
        }
        return (succeeded, failed)
    }.value
}
