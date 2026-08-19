import Foundation
import SwiftData

@MainActor
public final class LibraryImporter {
    public init() {}

    public func scanFolder(at url: URL, recursive: Bool = true) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let options: FileManager.DirectoryEnumerationOptions = recursive
            ? [.skipsHiddenFiles]
            : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: options
        ) else { return [] }

        for case let fileURL as URL in enumerator where RawFileType.isRaw(fileURL) {
            results.append(fileURL)
        }
        return results
    }

    /// Skips files already present *in this session* (matched by absolute path) and returns the
    /// count of newly registered assets. Dedup is session-scoped, not global: the same absolute
    /// path imported into a different session is treated as a new, separate `PhotoAsset`.
    @discardableResult
    public func importFiles(_ urls: [URL], into context: ModelContext, session: Session) throws -> Int {
        let existingPaths = Set((session.photos ?? []).map(\.filePath))

        var importedCount = 0
        for url in urls {
            let path = url.path
            guard !existingPaths.contains(path) else { continue }

            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let fileSize = (attrs?[.size] as? Int64) ?? 0
            let captureDate = ThumbnailProvider.captureDate(for: url)
            let dimensions = ThumbnailProvider.pixelDimensions(for: url)
            let bookmark = try? url.bookmarkData(options: [.minimalBookmark])

            let asset = PhotoAsset(
                filePath: path,
                bookmarkData: bookmark,
                fileName: url.lastPathComponent,
                fileExtension: url.pathExtension.lowercased(),
                session: session,
                captureDate: captureDate,
                fileSize: fileSize,
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height
            )
            context.insert(asset)
            importedCount += 1
        }

        if importedCount > 0 {
            try context.save()
        }
        return importedCount
    }
}
