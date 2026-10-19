import Foundation

/// A parsed 3D color lookup table (the industry-standard `.cube` format — Iridas/Resolve), used to
/// apply "film simulation"/creative-look grades exported from color tools or captured from real
/// film stocks and camera profiles. `data` is pre-packed as RGBA float32 in the exact byte layout
/// `CIColorCubeWithColorSpace` expects (red fastest, then green, then blue; alpha padded to `1`)
/// so `LUT3DFilter.apply(to:params:)` can hand it straight to Core Image with no further
/// conversion.
public struct LUT3D: Equatable, Sendable {
    /// The cube's edge length — a 33-point cube has `size == 33` and `size*size*size` entries.
    public var size: Int
    /// `size*size*size` RGBA float32 samples, red-fastest order, as raw bytes.
    public var data: Data
    public var title: String?

    public init(size: Int, data: Data, title: String? = nil) {
        self.size = size
        self.data = data
        self.title = title
    }
}

public enum LUT3DParseError: Error, Equatable {
    /// No `LUT_3D_SIZE` line was found.
    case missingSize
    /// `LUT_3D_SIZE` was present but not a usable integer (needs to be at least 2).
    case invalidSize(String)
    /// A data row didn't parse as three whitespace-separated floats.
    case malformedDataLine(String)
    /// Fewer (or more) data rows were present than `size*size*size` calls for.
    case incompleteData(expected: Int, found: Int)
}

/// Parses `.cube` LUT files into `LUT3D` values ready for `LUT3DFilter`.
public enum LUT3DLoader {
    /// Parses the text contents of a `.cube` file. Only 3D LUTs are supported — `LUT_1D_SIZE` rows
    /// are ignored, since nothing in this codebase applies a 1D LUT.
    ///
    /// `DOMAIN_MIN`/`DOMAIN_MAX` are recognized but not applied: every film-simulation `.cube` seen
    /// in practice uses the default `0 0 0`/`1 1 1` domain (they're authored against a
    /// display-referred sRGB preview, not scene-linear/log data), and supporting a remapped domain
    /// would add a `CIColorMatrix` pre-pass with nothing exercising it.
    ///
    /// - Parameter title: Fallback title used when the file has no `TITLE` line of its own.
    public static func parse(_ contents: String, title: String? = nil) throws -> LUT3D {
        var size: Int?
        var parsedTitle = title
        var samples: [Float] = []

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("TITLE") {
                let value = line.dropFirst("TITLE".count).trimmingCharacters(in: .whitespaces)
                parsedTitle = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                continue
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                let value = line.dropFirst("LUT_3D_SIZE".count).trimmingCharacters(in: .whitespaces)
                guard let parsedSize = Int(value), parsedSize >= 2 else {
                    throw LUT3DParseError.invalidSize(value)
                }
                size = parsedSize
                continue
            }
            if line.hasPrefix("LUT_1D_SIZE") || line.hasPrefix("DOMAIN_MIN") || line.hasPrefix("DOMAIN_MAX") {
                continue
            }

            let components = line.split(whereSeparator: \.isWhitespace)
            guard components.count >= 3,
                  let r = Float(components[0]), let g = Float(components[1]), let b = Float(components[2])
            else {
                throw LUT3DParseError.malformedDataLine(line)
            }
            samples.append(contentsOf: [r, g, b, 1])
        }

        guard let size else { throw LUT3DParseError.missingSize }
        let expectedSamples = size * size * size
        guard samples.count == expectedSamples * 4 else {
            throw LUT3DParseError.incompleteData(expected: expectedSamples, found: samples.count / 4)
        }

        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return LUT3D(size: size, data: data, title: parsedTitle)
    }

    /// Loads and parses a `.cube` file from disk. Falls back to the file's own name (minus
    /// extension) as the title when the file has no `TITLE` line of its own.
    public static func load(contentsOf url: URL) throws -> LUT3D {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try parse(contents, title: url.deletingPathExtension().lastPathComponent)
    }
}
