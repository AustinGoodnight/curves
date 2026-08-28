import Vision
import CoreImage
import CoreVideo
import CoreGraphics
import Foundation

/// The "click an object to select it" half of the Remove Object tool — the other half
/// (synthesizing a fill for the selected mask) is `InpaintingFilter` in `RawEngine`. Uses
/// `VNGenerateForegroundInstanceMaskRequest`, available since macOS 14.0 — this app's current
/// floor, confirmed directly against Xcode's actual Vision.framework headers rather than assumed
/// from documentation, after an earlier, newer-sounding "tap to segment" API this was drafted
/// against turned out not to exist in the real SDK. No `@available` gating needed as a result.
enum ObjectSelectionMask {
    enum SelectionError: Error {
        case noInstancesDetected
        case pointNotOnAnyInstance
        case maskGenerationFailed
    }

    /// One Vision segmentation pass over a photo, reusable across multiple tap points on that same
    /// photo (e.g. while the user tries a different spot after missing the object they meant)
    /// without re-running the seconds-scale segmentation each time.
    final class Session {
        private let observation: VNInstanceMaskObservation
        private let requestHandler: VNImageRequestHandler
        private let context = CIContext()

        init(image: CGImage) throws {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            guard let observation = request.results?.first else { throw SelectionError.noInstancesDetected }
            self.observation = observation
            self.requestHandler = handler
        }

        /// `point` is normalized (0...1), top-left origin — same convention as `SpotRemoval`'s own
        /// coordinates (see its doc comment on `RawEngine`).
        func mask(at point: CGPoint) throws -> CGImage {
            let index = Self.instanceIndex(in: observation.instanceMask, atNormalizedPoint: point)
            guard index != 0 else { throw SelectionError.pointNotOnAnyInstance }
            guard let pixelBuffer = try? observation.generateScaledMaskForImage(forInstances: IndexSet([index]), from: requestHandler) else {
                throw SelectionError.maskGenerationFailed
            }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let mask = context.createCGImage(ciImage, from: ciImage.extent) else { throw SelectionError.maskGenerationFailed }
            return mask
        }

        /// Reads a single pixel directly out of `pixelBuffer`'s raw memory (0 = background,
        /// otherwise the 1-based instance index at that point) rather than going through Core
        /// Image — this buffer holds discrete integer labels, not display-referred color, and
        /// `CIImage`'s rendering pipeline can silently reinterpret/distort raw integer values
        /// through its own color-management assumptions (this was tried first and reliably read
        /// back 0 everywhere, which is what motivated switching to a direct memory read).
        /// `CVPixelBuffer` rows are always stored top-down in memory, so `point`'s own top-down
        /// convention needs no flip here — unlike everywhere else in this codebase that samples
        /// through Core Image's bottom-up coordinate space.
        private static func instanceIndex(in pixelBuffer: CVPixelBuffer, atNormalizedPoint point: CGPoint) -> Int {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard width > 0, height > 0 else { return 0 }
            let pixelX = min(max(Int((point.x * CGFloat(width)).rounded(.down)), 0), width - 1)
            let pixelY = min(max(Int((point.y * CGFloat(height)).rounded(.down)), 0), height - 1)

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let rowStart = base.advanced(by: pixelY * bytesPerRow)

            switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
            case kCVPixelFormatType_OneComponent8:
                return Int(rowStart.assumingMemoryBound(to: UInt8.self)[pixelX])
            case kCVPixelFormatType_OneComponent16:
                return Int(rowStart.assumingMemoryBound(to: UInt16.self)[pixelX])
            case kCVPixelFormatType_OneComponent32Float:
                return Int(rowStart.assumingMemoryBound(to: Float.self)[pixelX].rounded())
            default:
                // Undocumented fallback — `generateMaskForInstances` documents its own (different)
                // result as 32-bit float, so that's the most likely format for this one too.
                return Int(rowStart.assumingMemoryBound(to: Float.self)[pixelX].rounded())
            }
        }
    }
}
