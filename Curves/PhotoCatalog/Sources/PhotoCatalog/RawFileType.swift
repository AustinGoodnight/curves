import Foundation

public enum RawFileType {
    public static let extensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "erf", "mrw", "rwl"
    ]

    /// Standard, already-demosaiced image formats — decoded by `RawImageRenderer` via a plain
    /// `CIImage(contentsOf:)` fallback rather than `CIRAWFilter`, so exposure/white-balance/
    /// sharpness edits are no-ops on these (see that fallback's doc comment).
    public static let standardImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"
    ]

    public static func isRaw(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public static func isSupportedImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return extensions.contains(ext) || standardImageExtensions.contains(ext)
    }
}
