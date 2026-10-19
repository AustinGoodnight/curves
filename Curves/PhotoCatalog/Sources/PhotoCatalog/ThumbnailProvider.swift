import Foundation
import ImageIO
import CoreGraphics

public enum ThumbnailProvider {
    /// Uses the embedded preview already stored in the RAW file by the camera when present,
    /// falling back to a full decode only if no embedded thumbnail exists.
    public static func thumbnail(for url: URL, maxPixelSize: Int = 640) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public static func captureDate(for url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.date(from: dateString)
    }

    public static func pixelDimensions(for url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return (0, 0) }
        return (width, height)
    }

    /// Camera/lens/exposure readouts shown in the editor sidebar — pulled from the EXIF/TIFF
    /// dictionaries the same way `captureDate`/`pixelDimensions` read theirs, so a file that fails
    /// to yield any of these (a RAW variant missing a tag) just leaves that one field at its
    /// empty/zero default rather than failing the whole import.
    public static func captureMetadata(for url: URL) -> CaptureMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return CaptureMetadata()
        }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let cameraMake = tiff?[kCGImagePropertyTIFFMake] as? String
        let cameraModel = tiff?[kCGImagePropertyTIFFModel] as? String
        return CaptureMetadata(
            cameraModel: [cameraMake, cameraModel].compactMap { $0 }.joined(separator: " "),
            lensModel: exif?[kCGImagePropertyExifLensModel] as? String ?? "",
            iso: (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first ?? 0,
            shutterSpeed: exif?[kCGImagePropertyExifExposureTime] as? Double ?? 0,
            aperture: exif?[kCGImagePropertyExifFNumber] as? Double ?? 0,
            focalLength: exif?[kCGImagePropertyExifFocalLength] as? Double ?? 0
        )
    }
}

public struct CaptureMetadata: Sendable {
    public var cameraModel: String = ""
    public var lensModel: String = ""
    public var iso: Int = 0
    /// Seconds, e.g. `0.004` for 1/250s — `PhotoAsset.shutterSpeedDisplay` formats this for
    /// display rather than storing an already-formatted string.
    public var shutterSpeed: Double = 0
    /// f-number, e.g. `2.8` for f/2.8.
    public var aperture: Double = 0
    /// Millimeters.
    public var focalLength: Double = 0

    public init(
        cameraModel: String = "", lensModel: String = "", iso: Int = 0,
        shutterSpeed: Double = 0, aperture: Double = 0, focalLength: Double = 0
    ) {
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.iso = iso
        self.shutterSpeed = shutterSpeed
        self.aperture = aperture
        self.focalLength = focalLength
    }
}
