import Foundation
import CoreGraphics
import CoreImage
import UniformTypeIdentifiers
import RawEngine

/// Turns an arbitrary mask (however it was acquired — Vision's click-to-select in
/// `RemoveObjectEditorOverlay`, or a hand-painted brush in `PaintedFillEditorOverlay`) into a baked
/// `ObjectRemoval`: crop a padded, square region around it, run it through the vendored LaMa model
/// (`InpaintingFilter`), resize the result back, and encode everything `ObjectRemovalKernel` needs
/// to composite it later. A plain enum, not a `View`'s static methods, specifically so it carries no
/// implicit main-actor isolation — every caller here already runs this from inside a
/// `Task.detached`, since the model call is genuinely expensive (order of a second or more).
enum ObjectRemovalBaking {
    enum BakingError: Error {
        case emptyMask
        case cropFailed
        case encodingFailed
    }

    /// Crops `previewImage`/`maskImage` to the same padded square (see `paddedSquareCrop`), runs
    /// `InpaintingFilter.fill`, and resizes the result back to that crop's own size.
    static func makeObjectRemoval(previewImage: CGImage, maskImage: CGImage, imageSize: CGSize) throws -> ObjectRemoval {
        guard let bbox = normalizedBoundingBox(of: maskImage) else { throw BakingError.emptyMask }
        let square = paddedSquareCrop(around: bbox, imageSize: imageSize)
        guard let croppedImage = previewImage.cropping(to: square), let croppedMask = maskImage.cropping(to: square) else {
            throw BakingError.cropFailed
        }
        let filled = try InpaintingFilter.fill(image: croppedImage, mask: croppedMask)
        let resized = try resize(filled, to: square.size)
        guard let maskData = pngData(from: maskImage), let patchData = pngData(from: resized) else {
            throw BakingError.encodingFailed
        }
        return ObjectRemoval(
            maskData: maskData,
            cropX: square.origin.x / imageSize.width, cropY: square.origin.y / imageSize.height,
            cropWidth: square.width / imageSize.width, cropHeight: square.height / imageSize.height,
            previewPatchData: patchData
        )
    }

    /// Scans a small (128x128) downsample of `mask` for the bounding box of its non-black region —
    /// cheap regardless of the mask's native resolution, and plenty precise for padding purposes
    /// (the padding added in `paddedSquareCrop` dwarfs the ~1% quantization error this introduces).
    /// Returns a normalized (0...1), top-left-origin rect — same convention as `SpotRemoval`'s
    /// coordinates.
    static func normalizedBoundingBox(of mask: CGImage) -> CGRect? {
        let gridSize = 128
        let ciImage = CIImage(cgImage: mask)
        guard ciImage.extent.width > 0, ciImage.extent.height > 0 else { return nil }
        let scale = CGAffineTransform(scaleX: CGFloat(gridSize) / ciImage.extent.width, y: CGFloat(gridSize) / ciImage.extent.height)
        let scaled = ciImage.transformed(by: scale)
        var buffer = [UInt8](repeating: 0, count: gridSize * gridSize)
        let context = CIContext()
        context.render(
            scaled, toBitmap: &buffer, rowBytes: gridSize,
            bounds: CGRect(x: 0, y: 0, width: gridSize, height: gridSize), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()
        )
        var minX = gridSize, minY = gridSize, maxX = -1, maxY = -1
        for y in 0..<gridSize {
            for x in 0..<gridSize where buffer[y * gridSize + x] > 32 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // `buffer` is in Core Image's bottom-left-origin space (row 0 of the render bounds is the
        // image's bottom) — flip to this module's top-left-origin convention.
        let x0 = CGFloat(minX) / CGFloat(gridSize)
        let x1 = CGFloat(maxX + 1) / CGFloat(gridSize)
        let bottomFrac = CGFloat(minY) / CGFloat(gridSize)
        let topFrac = CGFloat(maxY + 1) / CGFloat(gridSize)
        return CGRect(x: x0, y: 1 - topFrac, width: x1 - x0, height: topFrac - bottomFrac)
    }

    /// Pads `bbox` (fractionally, so a bigger object gets proportionally more surrounding context)
    /// and expands it to a square centered on the same point — `InpaintingFilter` requires a square
    /// input (see its doc comment) and benefits from context beyond the object's own silhouette to
    /// blend into. Clamped to fit inside `imageSize` without changing aspect, shrinking the square
    /// if necessary rather than letting it run off the image's edge.
    static func paddedSquareCrop(around bbox: CGRect, imageSize: CGSize, paddingFraction: CGFloat = 0.6) -> CGRect {
        let pixelBBox = CGRect(
            x: bbox.minX * imageSize.width, y: bbox.minY * imageSize.height,
            width: bbox.width * imageSize.width, height: bbox.height * imageSize.height
        )
        let padded = pixelBBox.insetBy(dx: -pixelBBox.width * paddingFraction, dy: -pixelBBox.height * paddingFraction)
        let side = min(max(padded.width, padded.height), min(imageSize.width, imageSize.height))
        var square = CGRect(x: padded.midX - side / 2, y: padded.midY - side / 2, width: side, height: side)
        square.origin.x = min(max(square.origin.x, 0), imageSize.width - side)
        square.origin.y = min(max(square.origin.y, 0), imageSize.height - side)
        return square
    }

    static func resize(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
        guard ciImage.extent.width > 0, ciImage.extent.height > 0 else { throw BakingError.encodingFailed }
        let scale = CGAffineTransform(scaleX: size.width / ciImage.extent.width, y: size.height / ciImage.extent.height)
        let scaled = ciImage.transformed(by: scale)
        let context = CIContext()
        guard let result = context.createCGImage(scaled, from: CGRect(origin: .zero, size: size)) else {
            throw BakingError.encodingFailed
        }
        return result
    }

    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
