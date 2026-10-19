import CoreImage
import Foundation

/// "Click something that should be white/grey" white balance — hands the clicked spot to
/// `CIRAWFilter.neutralLocation`, which computes the Temp/Tint that make that spot neutral and
/// reports them back through `neutralTemperature`/`neutralTint`. Verified against a real CR2: the
/// returned values, rendered, bring the sampled patch to equal R/G/B (e.g. a bluish patch at
/// (0.11, 0.14, 0.18) linear came out (0.150, 0.148, 0.150)).
///
/// `neutralLocation` is in the full, *uncropped* decoded image's own coordinates (Core Image space:
/// origin bottom-left, at `scaleFactor` 1 — the `outputImage.extent` of a fresh filter), while the
/// user clicks on the cropped/straightened preview. `sourcePoint(forDisplayPoint:crop:imageSize:)`
/// inverts `CropTransform` exactly to get from one to the other. Lens correction's small geometric
/// warp is *not* inverted (it's applied before crop and is a few pixels at most on a real lens), so
/// the picked spot can land a hair off on a heavily distorted lens — irrelevant for picking a
/// neutral area, which is never a single pixel wide.
public enum WhiteBalancePicker {
    /// The Temp/Tint that neutralize the spot under `displayPoint` — a point normalized to the
    /// *displayed* (post-crop) preview, origin top-left, 0...1 on both axes. Uses its own fresh
    /// `CIRAWFilter` rather than the renderer's shared one, so the editor's cached decode isn't
    /// disturbed. `nil` for non-RAW files (no `CIRAWFilter`, so no camera white balance to solve).
    /// Does a RAW open, so call it off the main thread.
    public static func neutralWhiteBalance(
        url: URL, displayPoint: CGPoint, crop: CropParameters?
    ) -> (temperature: Double, tint: Double)? {
        guard let filter = CIRAWFilter(imageURL: url), let extent = filter.outputImage?.extent,
              extent.width > 0, extent.height > 0 else { return nil }
        let source = sourcePoint(forDisplayPoint: displayPoint, crop: crop, imageSize: extent.size)
        filter.neutralLocation = CGPoint(x: extent.minX + source.x, y: extent.minY + source.y)
        return (Double(filter.neutralTemperature), Double(filter.neutralTint))
    }

    /// Inverse of `CropTransform.apply`: maps a top-left-origin normalized point on the cropped
    /// output back to a Core Image (bottom-left origin) pixel point in the unrotated, uncropped
    /// image of `imageSize`. Mirrors that function step by step — its `rect` is normalized within
    /// the *rotated* image's bounding box in CI space, and the rotation is about the image center.
    public static func sourcePoint(forDisplayPoint point: CGPoint, crop: CropParameters?, imageSize: CGSize) -> CGPoint {
        let rect = crop?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let radians = CGFloat((crop?.angleDegrees ?? 0) * .pi / 180)
        let w = imageSize.width, h = imageSize.height

        // Display (top-left origin) → normalized position in the rotated bounding box (CI, y up).
        let rx = rect.minX + point.x * rect.width
        let ry = rect.minY + (1 - point.y) * rect.height

        // Rotated bounding box, centered on the image center (as `CIImage.transformed` produces).
        let rotatedW = abs(w * cos(radians)) + abs(h * sin(radians))
        let rotatedH = abs(w * sin(radians)) + abs(h * cos(radians))
        let cx = w / 2, cy = h / 2
        let px = cx - rotatedW / 2 + rx * rotatedW
        let py = cy - rotatedH / 2 + ry * rotatedH

        // Undo the rotation about the center.
        let dx = px - cx, dy = py - cy
        let qx = cx + dx * cos(-radians) - dy * sin(-radians)
        let qy = cy + dx * sin(-radians) + dy * cos(-radians)
        return CGPoint(x: min(max(qx, 0), w - 1), y: min(max(qy, 0), h - 1))
    }
}
