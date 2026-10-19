import Foundation
import CoreGraphics

public final class ThumbnailCache: @unchecked Sendable {
    public static let shared = ThumbnailCache()

    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, CGImageBox>()

    private init() {
        cache.countLimit = 2000
    }

    public func image(for key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    public func setImage(_ image: CGImage, for key: String) {
        cache.setObject(CGImageBox(image), forKey: key as NSString)
    }
}
