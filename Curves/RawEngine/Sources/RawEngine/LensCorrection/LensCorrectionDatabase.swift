import Foundation

/// One `<lens>` entry's parsed calibration data — one lensfun XML file has many of these, each
/// with its own maker/model/crop factor and zero or more focal-length-indexed distortion/
/// vignetting/TCA measurements. Distortion and TCA entries are `(model, focal, terms)` tuples;
/// `terms` is always padded to a fixed length (3 for distortion, 6 for TCA) regardless of how many
/// attributes that particular model actually uses, so `LensCorrectionDatabase`'s interpolation code
/// never has to special-case a shorter array.
private struct DBLens {
    var maker: String
    var models: [String]
    var cropFactor: Double
    var aspectRatio: Double
    var distortions: [(model: String, focal: Double, terms: [Double])] = []
    var vignettings: [(focal: Double, aperture: Double, distance: Double, terms: [Double])] = []
    var tcas: [(model: String, focal: Double, terms: [Double])] = []
}

private struct DBCamera {
    var maker: String
    var models: [String]
    var cropFactor: Double
}

/// Parses and indexes lensfun's real, crowd-sourced camera/lens correction database — bundled as
/// XML straight from https://github.com/lensfun/lensfun (`Resources/db/*.xml`, unmodified, 59
/// files/~1500 lenses) as an app resource, rather than vendoring lensfun's own C library (which
/// pulls in glib/libpng/gettext and a CMake build lensfun doesn't ship as source-embeddable — not a
/// practical fit for this package's pure-Swift/CoreImage module pattern). `LensCorrectionKernel`
/// reimplements lensfun's own published correction math against this data instead.
///
/// **Interpolation is a deliberate simplification of lensfun's own algorithm**, not a byte-for-byte
/// port: real lensfun uses a 4-point Catmull-Rom-style spline across focal-length calibration
/// points for distortion/TCA, and inverse-distance-weighting across every focal/aperture/distance
/// calibration point at once for vignetting (see `lens.cpp`'s `InterpolateDistortion`/
/// `InterpolateVignetting`). This instead linearly interpolates between the two calibration points
/// bracketing the shot's actual focal length (and, for vignetting, additionally picks the nearest
/// available aperture at each of those two focals, defaulting to the farthest available focus
/// distance since this app has no focus-distance EXIF to match against). For the common case —
/// interpolating between two reasonably-spaced calibration points, or an exact match, which many
/// primes have only one of anyway — this produces materially the same correction; it diverges most
/// at the extremes of a lens's calibrated focal range, where lensfun's spline extrapolates and this
/// clamps to the nearest endpoint instead.
///
/// `shared` parses all bundled XML files once, lazily, on first use — matching this codebase's
/// established "expensive work must not repeat on every render" rule (see
/// `docs/PERFORMANCE.md`). A photo's own EXIF readouts don't change between renders, so a resolved
/// `LensCorrectionParameters` is cheap to recompute per render, but `profile(...)` itself (a linear
/// scan with string matching over ~1500 lenses) should not be called from a SwiftUI `body` — see
/// `EditorParameters.lensCorrectionParameters(for:)` for where it's actually called from instead.
public final class LensCorrectionDatabase: @unchecked Sendable {
    public static let shared = LensCorrectionDatabase()

    private let lenses: [DBLens]
    private let cameras: [DBCamera]

    private init() {
        var parsedLenses: [DBLens] = []
        var parsedCameras: [DBCamera] = []
        for url in Self.databaseFileURLs() {
            guard let data = try? Data(contentsOf: url) else { continue }
            let delegate = LensDatabaseXMLParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = delegate
            xmlParser.parse()
            parsedLenses.append(contentsOf: delegate.lenses)
            parsedCameras.append(contentsOf: delegate.cameras)
        }
        lenses = parsedLenses
        cameras = parsedCameras
    }

    private static func databaseFileURLs() -> [URL] {
        guard let dbDirectory = Bundle.module.url(forResource: "db", withExtension: nil) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: dbDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "xml" }
    }

    /// Resolves a `LensCorrectionParameters` for one shot from its own EXIF readouts. `nil` means no
    /// lens in the database matched `lensModel` closely enough (see `matchLens`) — callers should
    /// treat this the same as "no correction data available for this lens", not an error.
    /// `intensity` on the result is always `1` (full correction) — callers apply their own
    /// user-facing "Amount" dial on top, see `EditorParameters.lensCorrectionParameters(for:)`.
    public func profile(cameraModel: String, lensModel: String, focalLength: Double, aperture: Double) -> LensCorrectionParameters? {
        guard focalLength > 0, let lens = matchLens(lensModel) else { return nil }
        let cameraCropFactor = matchCamera(cameraModel)?.cropFactor ?? lens.cropFactor

        let distortion = interpolateDistortion(in: lens, focal: focalLength)
        let vignetting = aperture > 0 ? interpolateVignetting(in: lens, focal: focalLength, aperture: aperture) : nil
        let tca = interpolateTCA(in: lens, focal: focalLength)
        guard distortion != nil || vignetting != nil || tca != nil else { return nil }

        return LensCorrectionParameters(
            distortion: distortion,
            vignetting: vignetting,
            tca: tca,
            realFocalLength: focalLength,
            calibrationCropFactor: lens.cropFactor,
            calibrationAspectRatio: lens.aspectRatio,
            cameraCropFactor: cameraCropFactor
        )
    }

    // MARK: - Matching

    /// Lowercases and reduces to whitespace-separated alphanumeric tokens — EXIF lens/camera model
    /// strings and this database's own naming rarely agree on punctuation, spacing, or case
    /// ("NIKON CORPORATION" vs. "Nikon"; "18-55mm f/3.5-5.6" vs. "18-55mm F3.5-5.6"), so matching
    /// happens on normalized token overlap rather than exact/substring equality.
    private static func normalize(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
    }

    /// Requires *either* the lens' own maker name to appear in the EXIF string and a moderate
    /// token overlap, *or* a near-total token overlap on its own. The second path matters more than
    /// it looks: for third-party lenses (Sigma/Tamron/Tokina), camera bodies routinely report a
    /// generic, maker-less EXIF lens name (e.g. a Sony body shooting a Tamron zoom reports just "E
    /// 17-28mm F2.8-2.8", no "Tamron" anywhere) — and the database's own convention for exactly this
    /// case is to make the *primary*, un-langed `<model>` match that generic EXIF string verbatim,
    /// with the maker-inclusive name relegated to a `lang="en"` variant. A maker-only gate rejects
    /// this real, common case outright even at a perfect model-token match; a database-wide check
    /// confirms no `<model>` string is duplicated verbatim across two different makers, so a
    /// near-total overlap is safe to trust without maker confirmation.
    private func matchLens(_ exifLensModel: String) -> DBLens? {
        guard !exifLensModel.isEmpty else { return nil }
        let exifNorm = Self.normalize(exifLensModel)
        let exifTokens = Set(exifNorm.split(separator: " ").map(String.init))
        guard !exifTokens.isEmpty else { return nil }

        var best: (lens: DBLens, score: Double)?
        for lens in lenses {
            let makerNorm = Self.normalize(lens.maker)
            let makerConfirmed = !makerNorm.isEmpty && exifNorm.contains(makerNorm)
            for model in lens.models {
                let modelTokens = Set(Self.normalize(model).split(separator: " ").map(String.init))
                guard !modelTokens.isEmpty else { continue }
                let score = Double(exifTokens.intersection(modelTokens).count) / Double(modelTokens.count)
                let qualifies = (makerConfirmed && score >= 0.5) || score >= 0.85
                if qualifies, score > (best?.score ?? 0) {
                    best = (lens, score)
                }
            }
        }
        return best?.lens
    }

    private func matchCamera(_ exifCameraModel: String) -> DBCamera? {
        guard !exifCameraModel.isEmpty else { return nil }
        let exifNorm = Self.normalize(exifCameraModel)
        let exifTokens = Set(exifNorm.split(separator: " ").map(String.init))
        guard !exifTokens.isEmpty else { return nil }

        var best: (camera: DBCamera, score: Double)?
        for camera in cameras {
            let makerNorm = Self.normalize(camera.maker)
            guard !makerNorm.isEmpty, exifNorm.contains(makerNorm) else { continue }
            for model in camera.models {
                let modelTokens = Set(Self.normalize(model).split(separator: " ").map(String.init))
                guard !modelTokens.isEmpty else { continue }
                let score = Double(exifTokens.intersection(modelTokens).count) / Double(modelTokens.count)
                if score >= 0.5, score > (best?.score ?? 0) {
                    best = (camera, score)
                }
            }
        }
        return best?.camera
    }

    // MARK: - Interpolation

    /// Finds the two calibration entries bracketing `focal` (by ascending focal length) and the
    /// linear-interpolation fraction between them — `(entry, entry, 0)` when `focal` falls outside
    /// the calibrated range (clamped to the nearest endpoint) or there's only one calibration point.
    private func bracket(
        _ entries: [(model: String, focal: Double, terms: [Double])], focal: Double
    ) -> ((model: String, focal: Double, terms: [Double]), (model: String, focal: Double, terms: [Double]), Double)? {
        guard let first = entries.first else { return nil }
        guard entries.count > 1 else { return (first, first, 0) }
        if focal <= entries[0].focal { return (entries[0], entries[0], 0) }
        let last = entries[entries.count - 1]
        if focal >= last.focal { return (last, last, 0) }
        for i in 0..<(entries.count - 1) {
            let f0 = entries[i].focal, f1 = entries[i + 1].focal
            if focal >= f0, focal <= f1 {
                let t = f1 > f0 ? (focal - f0) / (f1 - f0) : 0
                return (entries[i], entries[i + 1], t)
            }
        }
        return (last, last, 0)
    }

    private func interpolateTerms(_ a: [Double], _ b: [Double], t: Double) -> [Double] {
        zip(a, b).map { $0 + ($1 - $0) * t }
    }

    private func interpolateDistortion(in lens: DBLens, focal: Double) -> LensDistortionModel? {
        guard !lens.distortions.isEmpty else { return nil }
        // Only the first-encountered model is used if a lens' calibration mixes models — matches
        // lensfun's own "take into account just the first encountered lens model" rule.
        let modelName = lens.distortions[0].model
        let sameModel = lens.distortions.filter { $0.model == modelName }.sorted { $0.focal < $1.focal }
        guard let (lo, hi, t) = bracket(sameModel, focal: focal) else { return nil }
        let terms = interpolateTerms(lo.terms, hi.terms, t: t)
        switch modelName {
        case "poly3": return .poly3(k1: terms[0])
        case "poly5": return .poly5(k1: terms[0], k2: terms[1])
        case "ptlens": return .ptlens(a: terms[0], b: terms[1], c: terms[2])
        default: return nil
        }
    }

    private func interpolateTCA(in lens: DBLens, focal: Double) -> LensTCAModel? {
        guard !lens.tcas.isEmpty else { return nil }
        let modelName = lens.tcas[0].model
        let sameModel = lens.tcas.filter { $0.model == modelName }.sorted { $0.focal < $1.focal }
        guard let (lo, hi, t) = bracket(sameModel, focal: focal) else { return nil }
        let terms = interpolateTerms(lo.terms, hi.terms, t: t)
        switch modelName {
        case "linear": return .linear(kr: terms[0], kb: terms[1])
        case "poly3": return .poly3(vr: terms[0], vb: terms[1], cr: terms[2], cb: terms[3], br: terms[4], bb: terms[5])
        default: return nil
        }
    }

    private func interpolateVignetting(in lens: DBLens, focal: Double, aperture: Double) -> LensVignettingTerms? {
        guard !lens.vignettings.isEmpty else { return nil }
        let focals = Array(Set(lens.vignettings.map(\.focal))).sorted()
        guard let (f0, f1, t) = bracketFocals(focals, focal: focal) else { return nil }
        guard let terms0 = nearestVignettingTerms(in: lens, focal: f0, aperture: aperture) else { return nil }
        guard let terms1 = nearestVignettingTerms(in: lens, focal: f1, aperture: aperture) else { return nil }
        let terms = interpolateTerms(terms0, terms1, t: t)
        return LensVignettingTerms(k1: terms[0], k2: terms[1], k3: terms[2])
    }

    private func bracketFocals(_ focals: [Double], focal: Double) -> (Double, Double, Double)? {
        guard let first = focals.first else { return nil }
        guard focals.count > 1 else { return (first, first, 0) }
        if focal <= focals[0] { return (focals[0], focals[0], 0) }
        let last = focals[focals.count - 1]
        if focal >= last { return (last, last, 0) }
        for i in 0..<(focals.count - 1) {
            if focal >= focals[i], focal <= focals[i + 1] {
                let t = focals[i + 1] > focals[i] ? (focal - focals[i]) / (focals[i + 1] - focals[i]) : 0
                return (focals[i], focals[i + 1], t)
            }
        }
        return (last, last, 0)
    }

    /// At a single calibrated focal length, picks the entry with the closest aperture — first
    /// narrowed to the farthest available focus distance (this app has no focus-distance EXIF to
    /// match against, so "far/infinity focus" is the most broadly representative choice; most
    /// lenses' vignetting entries repeat identical terms across their two or three sampled
    /// distances anyway, per the database's own calibration notes).
    private func nearestVignettingTerms(in lens: DBLens, focal: Double, aperture: Double) -> [Double]? {
        let atFocal = lens.vignettings.filter { $0.focal == focal }
        guard !atFocal.isEmpty else { return nil }
        let maxDistance = atFocal.map(\.distance).max() ?? 0
        let atDistance = atFocal.filter { $0.distance == maxDistance }
        return atDistance.min(by: { abs($0.aperture - aperture) < abs($1.aperture - aperture) })?.terms
    }
}

/// SAX-style parser for lensfun's `<lensdatabase>` XML schema — reads only what
/// `LensCorrectionDatabase` needs (`<camera>`/`<lens>` maker/model/cropfactor/aspect-ratio plus
/// `<calibration>`'s `<distortion>`/`<vignetting>`/`<tca>` entries); `<mount>` and every other
/// element is ignored. See https://lensfun.github.io/manual/latest/db-lens.html for the full schema.
private final class LensDatabaseXMLParser: NSObject, XMLParserDelegate {
    var lenses: [DBLens] = []
    var cameras: [DBCamera] = []

    private var inLens = false
    private var inCamera = false
    private var currentText = ""

    private var lensMaker = ""
    private var lensModels: [String] = []
    private var lensCropFactor: Double = 1
    private var lensAspectRatio: Double = 1.5
    private var lensDistortions: [(model: String, focal: Double, terms: [Double])] = []
    private var lensVignettings: [(focal: Double, aperture: Double, distance: Double, terms: [Double])] = []
    private var lensTCAs: [(model: String, focal: Double, terms: [Double])] = []

    private var cameraMaker = ""
    private var cameraModels: [String] = []
    private var cameraCropFactor: Double = 1

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String] = [:]) {
        currentText = ""
        switch elementName {
        case "lens":
            inLens = true
            lensMaker = ""
            lensModels = []
            lensCropFactor = 1
            lensAspectRatio = 1.5
            lensDistortions = []
            lensVignettings = []
            lensTCAs = []

        case "camera":
            inCamera = true
            cameraMaker = ""
            cameraModels = []
            cameraCropFactor = 1

        case "distortion":
            guard inLens, let model = attrs["model"], let focal = Double(attrs["focal"] ?? "") else { return }
            let terms: [Double]
            switch model {
            case "poly3": terms = [Double(attrs["k1"] ?? "0") ?? 0, 0, 0]
            case "poly5": terms = [Double(attrs["k1"] ?? "0") ?? 0, Double(attrs["k2"] ?? "0") ?? 0, 0]
            case "ptlens": terms = [Double(attrs["a"] ?? "0") ?? 0, Double(attrs["b"] ?? "0") ?? 0, Double(attrs["c"] ?? "0") ?? 0]
            default: return
            }
            lensDistortions.append((model, focal, terms))

        case "vignetting":
            guard inLens, attrs["model"] == "pa",
                  let focal = Double(attrs["focal"] ?? ""), let aperture = Double(attrs["aperture"] ?? "") else { return }
            let distance = Double(attrs["distance"] ?? "1000") ?? 1000
            let terms: [Double] = [Double(attrs["k1"] ?? "0") ?? 0, Double(attrs["k2"] ?? "0") ?? 0, Double(attrs["k3"] ?? "0") ?? 0]
            lensVignettings.append((focal, aperture, distance, terms))

        case "tca":
            guard inLens, let model = attrs["model"], let focal = Double(attrs["focal"] ?? "") else { return }
            let terms: [Double]
            switch model {
            case "linear":
                terms = [Double(attrs["kr"] ?? "1") ?? 1, Double(attrs["kb"] ?? "1") ?? 1, 0, 0, 0, 0]
            case "poly3":
                terms = [
                    Double(attrs["vr"] ?? "1") ?? 1, Double(attrs["vb"] ?? "1") ?? 1,
                    Double(attrs["cr"] ?? "0") ?? 0, Double(attrs["cb"] ?? "0") ?? 0,
                    Double(attrs["br"] ?? "0") ?? 0, Double(attrs["bb"] ?? "0") ?? 0
                ]
            default: return
            }
            lensTCAs.append((model, focal, terms))

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "maker":
            if inLens { lensMaker = text } else if inCamera { cameraMaker = text }
        case "model":
            if inLens { lensModels.append(text) } else if inCamera { cameraModels.append(text) }
        case "cropfactor":
            if inLens { lensCropFactor = Double(text) ?? 1 } else if inCamera { cameraCropFactor = Double(text) ?? 1 }
        case "aspect-ratio":
            if inLens {
                let parts = text.split(separator: ":")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), h > 0 {
                    lensAspectRatio = w / h
                }
            }
        case "lens":
            lenses.append(DBLens(
                maker: lensMaker, models: lensModels, cropFactor: lensCropFactor, aspectRatio: lensAspectRatio,
                distortions: lensDistortions, vignettings: lensVignettings, tcas: lensTCAs
            ))
            inLens = false
        case "camera":
            cameras.append(DBCamera(maker: cameraMaker, models: cameraModels, cropFactor: cameraCropFactor))
            inCamera = false
        default:
            break
        }
        currentText = ""
    }
}
