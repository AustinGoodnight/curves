import CoreImage
import Foundation
import Testing
@testable import RawEngine

@Suite("RawEngine")
struct RawEngineTests {
    static var testFileURL: URL? {
        let path = "\(NSHomeDirectory())/Pictures/test/_MG_1633.CR2"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    @Test func loadsRealRawFileAndReportsDefaults() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        #expect(renderer.nativeSize.width > 0)
        #expect(renderer.defaultBoostAmount > 0)
    }

    @Test func rendersPreviewWithinRequestedBounds() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        let image = renderer.renderPreview(params: .none, maxPixelSize: 400)
        let cgImage = try #require(image)
        #expect(max(cgImage.width, cgImage.height) <= 400)
    }

    @Test func differentExposureProducesDifferentPixels() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        let dark = renderer.renderPreview(params: RawEditParameters(exposure: -2), maxPixelSize: 200)
        let bright = renderer.renderPreview(params: RawEditParameters(exposure: 2), maxPixelSize: 200)
        let darkData = try #require(dark?.dataProvider?.data)
        let brightData = try #require(bright?.dataProvider?.data)
        #expect(darkData != brightData)
    }

    @Test func exportWritesAReadableJPEG() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try ExportPipeline.export(renderer: renderer, params: .none, format: .jpeg(quality: 0.8), to: outURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        #expect((attrs[.size] as? Int ?? 0) > 0)
    }

    @Test func filmicRGBRendersAndDiffersFromPassthrough() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        let plain = renderer.renderPreview(params: .none, maxPixelSize: 300)
        let filmic = renderer.renderPreview(
            params: RawEditParameters(filmicRGB: .darktableDefault),
            maxPixelSize: 300
        )
        let plainData = try #require(plain?.dataProvider?.data)
        let filmicData = try #require(filmic?.dataProvider?.data)
        #expect(plainData != filmicData)
    }

    @Test func filmicRGBExportProducesReadableJPEG() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try ExportPipeline.export(
            renderer: renderer,
            params: RawEditParameters(filmicRGB: .darktableDefault),
            format: .jpeg(quality: 0.8),
            to: outURL
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        #expect((attrs[.size] as? Int ?? 0) > 0)
    }

    @Test func colorBalanceRGBRendersAndDiffersFromPassthrough() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        var wheels = ColorBalanceRGBParameters.darktableDefault
        wheels.globalY = 0.15
        wheels.shadowsC = 0.3
        wheels.shadowsH = 30
        let plain = renderer.renderPreview(params: .none, maxPixelSize: 300)
        let graded = renderer.renderPreview(
            params: RawEditParameters(colorBalanceRGB: wheels),
            maxPixelSize: 300
        )
        let plainData = try #require(plain?.dataProvider?.data)
        let gradedData = try #require(graded?.dataProvider?.data)
        #expect(plainData != gradedData)
    }

    @Test func colorBalanceRGBExportProducesReadableJPEG() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: outURL) }
        var wheels = ColorBalanceRGBParameters.darktableDefault
        wheels.contrast = 0.2
        try ExportPipeline.export(
            renderer: renderer,
            params: RawEditParameters(filmicRGB: .darktableDefault, colorBalanceRGB: wheels),
            format: .jpeg(quality: 0.8),
            to: outURL
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        #expect((attrs[.size] as? Int ?? 0) > 0)
    }

    @Test func rgbCurveRendersAndDiffersFromPassthrough() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        let curve = RGBCurveParameters(points: [SIMD2(0, 0), SIMD2(0.25, 0.1), SIMD2(0.75, 0.9), SIMD2(1, 1)])
        let plain = renderer.renderPreview(params: .none, maxPixelSize: 300)
        let curved = renderer.renderPreview(params: RawEditParameters(rgbCurve: curve), maxPixelSize: 300)
        let plainData = try #require(plain?.dataProvider?.data)
        let curvedData = try #require(curved?.dataProvider?.data)
        #expect(plainData != curvedData)
    }

    @Test func rgbCurveExportProducesReadableJPEG() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: outURL) }
        let curve = RGBCurveParameters(points: [SIMD2(0, 0), SIMD2(0.5, 0.65), SIMD2(1, 1)])
        try ExportPipeline.export(
            renderer: renderer,
            params: RawEditParameters(filmicRGB: .darktableDefault, rgbCurve: curve),
            format: .jpeg(quality: 0.8),
            to: outURL
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        #expect((attrs[.size] as? Int ?? 0) > 0)
    }

    @Test func colorZonesRendersAndDiffersFromPassthrough() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        let zones = ColorZonesParameters(
            chromaPoints: [SIMD2(0.25, 0.8), SIMD2(0.75, 0.5)]
        )
        let plain = renderer.renderPreview(params: .none, maxPixelSize: 300)
        let zoned = renderer.renderPreview(params: RawEditParameters(colorZones: zones), maxPixelSize: 300)
        let plainData = try #require(plain?.dataProvider?.data)
        let zonedData = try #require(zoned?.dataProvider?.data)
        #expect(plainData != zonedData)
    }

    @Test func colorZonesExportProducesReadableJPEG() throws {
        guard let url = Self.testFileURL else { return }
        let renderer = RawImageRenderer()
        #expect(renderer.load(url: url))
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: outURL) }
        let zones = ColorZonesParameters(huePoints: [SIMD2(0.25, 0.6), SIMD2(0.75, 0.4)])
        try ExportPipeline.export(
            renderer: renderer,
            params: RawEditParameters(filmicRGB: .darktableDefault, colorZones: zones),
            format: .jpeg(quality: 0.8),
            to: outURL
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        #expect((attrs[.size] as? Int ?? 0) > 0)
    }
}

@Suite("ColorZonesMath")
struct ColorZonesMathTests {
    @Test func labRoundTripIsCloseToIdentity() {
        let samples: [Triplet] = [
            Triplet(x: 0.2, y: 0.5, z: 0.8),
            Triplet(x: 0.9, y: 0.1, z: 0.05),
            Triplet(x: 0.01, y: 0.01, z: 0.01),
            Triplet(x: 1.0, y: 1.0, z: 1.0)
        ]
        for rgb in samples {
            let lab = ColorZonesMath.rgbToLab(rgb)
            let roundTripped = ColorZonesMath.labToRGB(lab)
            #expect(abs(roundTripped.x - rgb.x) < 1e-6)
            #expect(abs(roundTripped.y - rgb.y) < 1e-6)
            #expect(abs(roundTripped.z - rgb.z) < 1e-6)
        }
    }

    @Test func neutralGrayHasNearZeroChroma() {
        let gray = Triplet(x: 0.5, y: 0.5, z: 0.5)
        let lab = ColorZonesMath.rgbToLab(gray)
        #expect(abs(lab.y) < 1e-6)
        #expect(abs(lab.z) < 1e-6)
    }
}

@Suite("RGBCurveSpline")
struct RGBCurveSplineTests {
    @Test func identityTwoPointCurveIsANoOp() {
        let spline = RGBCurveSpline(points: RGBCurveParameters.identityPoints.map { (x: $0.x, y: $0.y) })
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(abs(spline.evaluate(x) - x) < 1e-9)
        }
    }

    @Test func evaluationIsExactAtControlPoints() {
        let points: [(x: Double, y: Double)] = [(0, 0), (0.3, 0.5), (0.7, 0.4), (1, 1)]
        let spline = RGBCurveSpline(points: points)
        for point in points {
            #expect(abs(spline.evaluate(point.x) - point.y) < 1e-9)
        }
    }

    @Test func monotonicControlPointsProduceMonotonicCurve() {
        // The whole point of the monotone-Hermite variant over plain Catmull-Rom: it must not
        // overshoot/ring between monotonically increasing control points.
        let points: [(x: Double, y: Double)] = [(0, 0), (0.2, 0.1), (0.5, 0.5), (0.8, 0.9), (1, 1)]
        let spline = RGBCurveSpline(points: points)
        var previous = -Double.infinity
        for i in stride(from: 0, through: 1000, by: 1) {
            let x = Double(i) / 1000
            let y = spline.evaluate(x)
            #expect(y >= previous - 1e-9)
            previous = y
        }
    }

    @Test func outOfDomainValuesAreFlatExtrapolated() {
        let points: [(x: Double, y: Double)] = [(0.2, 0.1), (0.8, 0.9)]
        let spline = RGBCurveSpline(points: points)
        #expect(spline.evaluate(-1) == spline.evaluate(0.2))
        #expect(spline.evaluate(2) == spline.evaluate(0.8))
    }

    @Test func catmullRomIsExactAtControlPointsAndFlatIdentity() {
        // colorzones.c's default curve_type — flat 2-node identity (both y = 0.5) must stay
        // exactly 0.5 everywhere, same as the monotone-Hermite identity case.
        let flatPoints = ColorZonesParameters.identityPoints.map { (x: $0.x, y: $0.y) }
        let flat = RGBCurveSpline(points: flatPoints, type: .catmullRom)
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(abs(flat.evaluate(x) - 0.5) < 1e-9)
        }

        let points: [(x: Double, y: Double)] = [(0, 0), (0.3, 0.7), (0.6, 0.2), (1, 1)]
        let spline = RGBCurveSpline(points: points, type: .catmullRom)
        for point in points {
            #expect(abs(spline.evaluate(point.x) - point.y) < 1e-9)
        }
    }
}

@Suite("FilmicSpline")
struct FilmicSplineTests {
    @Test func splineIsContinuousAtLatitudeBoundaries() {
        let spline = FilmicSpline.compute(.darktableDefault)
        let epsilon = 1e-4

        let belowToe = FilmicSpline.evaluate(spline.latitudeMin - epsilon, spline)
        let atToe = FilmicSpline.evaluate(spline.latitudeMin, spline)
        #expect(abs(belowToe - atToe) < 1e-3)

        let belowShoulder = FilmicSpline.evaluate(spline.latitudeMax, spline)
        let aboveShoulder = FilmicSpline.evaluate(spline.latitudeMax + epsilon, spline)
        #expect(abs(belowShoulder - aboveShoulder) < 1e-3)
    }

    @Test func splineMapsBlackAndWhiteLogToTargetDisplayValues() {
        let params = FilmicRGBParameters.darktableDefault
        let spline = FilmicSpline.compute(params)

        let blackDisplay = FilmicSpline.evaluate(0.0, spline)
        let whiteDisplay = FilmicSpline.evaluate(1.0, spline)

        let expectedBlack = pow(params.blackPointTarget / 100.0, 1.0 / params.outputPower)
        let expectedWhite = pow(params.whitePointTarget / 100.0, 1.0 / params.outputPower)

        #expect(abs(blackDisplay - expectedBlack) < 1e-3)
        #expect(abs(whiteDisplay - expectedWhite) < 1e-3)
    }

    @Test func midSegmentSlopeMatchesContrast() {
        let spline = FilmicSpline.compute(.darktableDefault)
        let x0 = (spline.latitudeMin + spline.latitudeMax) / 2 - 0.001
        let x1 = (spline.latitudeMin + spline.latitudeMax) / 2 + 0.001
        let y0 = FilmicSpline.evaluate(x0, spline)
        let y1 = FilmicSpline.evaluate(x1, spline)
        let slope = (y1 - y0) / (x1 - x0)
        #expect(abs(slope - spline.m2Mid) < 1e-2)
    }

    /// Cross-checks the spline fit against parameters this app didn't choose — decoded from a
    /// real, darktable-authored edit (`~/Pictures/test/_MG_1633.CR2.xmp`, via
    /// `dev-tools/decode_darktable_params.py`). Values transcribed from that decode (see
    /// `dev-tools/README.md` for the full field dump and how it was verified). `spline_version`
    /// and `shadows`/`highlights` in that file are V3/poly4, matching this port's scope exactly.
    @Test func filmicSplineMatchesRealDarktableEditContinuity() {
        let params = FilmicRGBParameters(
            blackPointSource: -7.650000095367432,
            whitePointSource: 4.559999942779511,
            outputPower: 3.614816188812256,
            latitude: 0.009999999776482582,
            contrast: 1.0,
            saturation: 0.0,
            balance: 0.0
        )
        let spline = FilmicSpline.compute(params)
        let epsilon = 1e-4

        // Continuous at both latitude boundaries.
        #expect(abs(
            FilmicSpline.evaluate(spline.latitudeMin - epsilon, spline)
                - FilmicSpline.evaluate(spline.latitudeMin, spline)
        ) < 1e-3)
        #expect(abs(
            FilmicSpline.evaluate(spline.latitudeMax, spline)
                - FilmicSpline.evaluate(spline.latitudeMax + epsilon, spline)
        ) < 1e-3)

        // Endpoints land on the real edit's actual target black/white display values.
        let expectedBlack = pow(params.blackPointTarget / 100.0, 1.0 / params.outputPower)
        let expectedWhite = pow(params.whitePointTarget / 100.0, 1.0 / params.outputPower)
        #expect(abs(FilmicSpline.evaluate(0.0, spline) - expectedBlack) < 1e-3)
        #expect(abs(FilmicSpline.evaluate(1.0, spline) - expectedWhite) < 1e-3)

        // Monotonically increasing across [0,1] — the only domain real pixel data ever reaches,
        // since `log_tonemapping_v2` always clamps to [0,1] before the spline is evaluated.
        // (The fitted polynomials are not constrained to be monotonic if extrapolated outside
        // that range — that's true of darktable's own math too, not a bug in this port.)
        var previous = FilmicSpline.evaluate(0.0, spline)
        for i in 1...120 {
            let x = Double(i) / 120.0
            let y = FilmicSpline.evaluate(x, spline)
            #expect(y >= previous - 1e-6)
            previous = y
        }
    }
}

@Suite("ColorBalanceRGB")
struct ColorBalanceRGBTests {
    @Test func defaultParametersAreIdentity() {
        let derived = ColorBalanceRGBProcessor.compute(.darktableDefault)
        let samples: [Triplet] = [
            Triplet(x: 0.1845, y: 0.1845, z: 0.1845),
            Triplet(x: 0.02, y: 0.05, z: 0.01),
            Triplet(x: 0.8, y: 0.6, z: 0.4),
            Triplet(x: 1.5, y: 1.2, z: 0.9),
            Triplet(x: 0.001, y: 0.001, z: 0.001),
        ]
        for rgb in samples {
            let out = ColorBalanceRGBProcessor.apply(rgb, derived)
            #expect(abs(out.x - rgb.x) < 1e-4)
            #expect(abs(out.y - rgb.y) < 1e-4)
            #expect(abs(out.z - rgb.z) < 1e-4)
        }
    }

    @Test func negativeInputIsClippedNotIdentity() {
        let derived = ColorBalanceRGBProcessor.compute(.darktableDefault)
        let out = ColorBalanceRGBProcessor.apply(Triplet(x: -0.1, y: 0.2, z: 0.2), derived)
        #expect(out.x >= 0 && out.y >= 0 && out.z >= 0)
    }

    @Test func globalLiftMovesLuminanceInExpectedDirection() {
        var params = ColorBalanceRGBParameters.darktableDefault
        params.globalY = 0.2
        let derived = ColorBalanceRGBProcessor.compute(params)
        let grey = Triplet(x: 0.1845, y: 0.1845, z: 0.1845)
        let out = ColorBalanceRGBProcessor.apply(grey, derived)
        // A positive global luminance lift should brighten a mid-grey pixel.
        #expect(out.x > grey.x && out.y > grey.y && out.z > grey.z)
    }

    @Test func positiveContrastSteepensAroundGreyFulcrum() {
        var params = ColorBalanceRGBParameters.darktableDefault
        params.contrast = 0.5
        let derived = ColorBalanceRGBProcessor.compute(params)
        let dark = ColorBalanceRGBProcessor.apply(Triplet(x: 0.05, y: 0.05, z: 0.05), derived)
        let bright = ColorBalanceRGBProcessor.apply(Triplet(x: 0.5, y: 0.5, z: 0.5), derived)
        // Positive contrast should push shadows darker and highlights brighter relative to input.
        #expect(dark.x < 0.05)
        #expect(bright.x > 0.5)
    }

    /// Cross-checks the wheel derivation against real, darktable-authored params — decoded from
    /// `~/Pictures/test/_MG_1633.CR2.xmp` (`dev-tools/decode_darktable_params.py`). That edit's
    /// wheels (Y/C/H) are all neutral (0), only chroma_global/saturation_global/fulcrums are
    /// touched — saturation_global is part of the perceptual stage this port skips, so this
    /// only exercises the linear chroma boost, not a full match to darktable's own output.
    @Test func matchesRealDarktableEditForUnimplementedFieldsGracefully() {
        let params = ColorBalanceRGBParameters(
            shadowsWeight: 1.0,
            whiteFulcrum: 0.0,
            highlightsWeight: 1.0,
            chromaGlobal: 0.09140002727508545,
            hueAngle: 0.0,
            maskGreyFulcrum: 0.18449999392032623,
            vibrance: 0.0,
            greyFulcrum: 0.18449999392032623,
            contrast: 0.0
        )
        let derived = ColorBalanceRGBProcessor.compute(params)
        let out = ColorBalanceRGBProcessor.apply(Triplet(x: 0.3, y: 0.2, z: 0.4), derived)
        #expect(out.x.isFinite && out.y.isFinite && out.z.isFinite)
        #expect(out.x >= 0 && out.y >= 0 && out.z >= 0)
    }
}
