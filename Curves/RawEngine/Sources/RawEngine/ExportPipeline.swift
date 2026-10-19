import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

public enum ExportFormat {
    case jpeg(quality: Double)
    case tiff
    case png

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .png: return .png
        }
    }
}

public enum ExportError: Error {
    case renderFailed
    case destinationCreationFailed
    case finalizeFailed
}

public enum ExportPipeline {
    /// `maxLongEdge` downscales the rendered image's longer side to fit, for presets like
    /// "Instagram" that shouldn't ship a full-resolution RAW render — `nil` (every built-in preset
    /// except that one) exports at native resolution. Forwarded straight to
    /// `RawImageRenderer.renderFullResolution`, which does the actual scaling on the `CIImage`
    /// before rasterizing, same as `renderPreview`'s downscale.
    public static func export(
        renderer: RawImageRenderer,
        baseParams: RawBaseParameters,
        stageStack: [StageParameters],
        format: ExportFormat,
        maxLongEdge: CGFloat? = nil,
        to url: URL
    ) throws {
        guard let cgImage = renderer.renderFullResolution(baseParams: baseParams, stageStack: stageStack, maxLongEdge: maxLongEdge) else {
            throw ExportError.renderFailed
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.destinationCreationFailed
        }
        var options: [CFString: Any] = [:]
        if case .jpeg(let quality) = format {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.finalizeFailed
        }
    }
}
