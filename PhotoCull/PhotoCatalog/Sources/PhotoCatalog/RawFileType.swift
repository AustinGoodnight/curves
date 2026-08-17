import Foundation

public enum RawFileType {
    public static let extensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "erf", "mrw", "rwl"
    ]

    public static func isRaw(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
