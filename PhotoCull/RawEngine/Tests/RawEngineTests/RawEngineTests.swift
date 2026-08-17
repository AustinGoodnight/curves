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
}
