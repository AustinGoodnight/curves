import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

public enum ExportFormat {
    case jpeg(quality: Double)
    case tiff

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }
}

public enum ExportError: Error {
    case renderFailed
    case destinationCreationFailed
    case finalizeFailed
}

public enum ExportPipeline {
    public static func export(
        renderer: RawImageRenderer,
        params: RawEditParameters,
        format: ExportFormat,
        to url: URL
    ) throws {
        guard let cgImage = renderer.renderFullResolution(params: params) else {
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
