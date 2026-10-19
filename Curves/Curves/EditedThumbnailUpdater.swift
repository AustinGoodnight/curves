import CoreGraphics
import CoreImage
import PhotoCatalog

/// Downscales a just-finished, non-draft editor preview to grid/filmstrip thumbnail size and pushes
/// it into `ThumbnailCache` under the asset's own key (the same key `PhotoThumbnailCell`/
/// `FilmstripThumbnail`/`CompactPhotoThumbnail`/`CullingSideThumbnail` read), then bumps
/// `ThumbnailInvalidationBus` so any of those currently-visible cells for this asset reload and pick
/// it up. Also refreshes `CullingMainImage`'s own, separately-keyed (`#culling-preview`) cache entry
/// the same way — a second, independent write/bump under that suffixed key, not a shared one, since
/// that view intentionally keeps its own larger decode apart from the grid's (see its doc comment).
/// Without this, every one of these keeps showing `ThumbnailProvider`'s embedded RAW preview — the
/// as-shot image — no matter how the photo's been edited, until the app relaunches and something
/// happens to evict that cache entry.
///
/// Called from `EditorRenderCoordinator.onSettledRender`, which only fires for a settled (non-draft)
/// render — see that property's doc comment for why a draft mid-drag render must never trigger this.
func updateSessionThumbnail(for filePath: String, from renderedImage: CGImage) {
    Task.detached(priority: .utility) {
        let renderer = EditedThumbnailRenderer.shared
        let gridThumbnail = renderer.downscale(renderedImage, maxPixelSize: 640)
        let cullingPreview = renderer.downscale(renderedImage, maxPixelSize: 2048)
        // `ThumbnailCache` (an `NSCache`) is safe to write from any thread, but
        // `ThumbnailInvalidationBus`'s dictionary isn't — it's only ever touched from the main
        // thread otherwise (SwiftUI view bodies), so the bump itself hops back rather than racing
        // those reads.
        if let gridThumbnail { ThumbnailCache.shared.setImage(gridThumbnail, for: filePath) }
        if let cullingPreview { ThumbnailCache.shared.setImage(cullingPreview, for: filePath + "#culling-preview") }
        await MainActor.run {
            if gridThumbnail != nil { ThumbnailInvalidationBus.shared.bump(filePath) }
            if cullingPreview != nil { ThumbnailInvalidationBus.shared.bump(filePath + "#culling-preview") }
        }
    }
}

/// Holds the one `CIContext` this reuses across calls — creating a fresh context per call is real,
/// avoidable setup cost, and this only ever needs to shrink an already-decoded image, not do any of
/// `RawImageRenderer`'s own RAW-decode/kernel work.
private final class EditedThumbnailRenderer: @unchecked Sendable {
    static let shared = EditedThumbnailRenderer()
    private let context = CIContext()

    func downscale(_ image: CGImage, maxPixelSize: CGFloat) -> CGImage? {
        let longSide = CGFloat(max(image.width, image.height))
        guard longSide > maxPixelSize else { return image }
        let scale = maxPixelSize / longSide
        let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
