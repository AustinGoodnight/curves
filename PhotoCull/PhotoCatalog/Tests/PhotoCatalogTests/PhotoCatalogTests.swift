import Foundation
import SwiftData
import Testing
@testable import PhotoCatalog

@Suite("PhotoCatalog")
struct PhotoCatalogTests {
    @Test func rawFileTypeDetection() {
        #expect(RawFileType.isRaw(URL(fileURLWithPath: "/tmp/photo.CR2")))
        #expect(RawFileType.isRaw(URL(fileURLWithPath: "/tmp/photo.nef")))
        #expect(!RawFileType.isRaw(URL(fileURLWithPath: "/tmp/photo.jpg")))
    }

    @Test func ratingClampsToValidRange() {
        let asset = PhotoAsset(filePath: "/tmp/a.cr2", fileName: "a.cr2", fileExtension: "cr2", session: Session(name: "Test", folderURL: URL(fileURLWithPath: "/tmp")))
        asset.rating = 9
        #expect(asset.rating == 5)
        asset.rating = -3
        #expect(asset.rating == 0)
    }

    @Test func flagRoundTripsThroughRawStorage() {
        let asset = PhotoAsset(filePath: "/tmp/a.cr2", fileName: "a.cr2", fileExtension: "cr2", session: Session(name: "Test", folderURL: URL(fileURLWithPath: "/tmp")))
        asset.flag = .pick
        #expect(asset.flagRaw == FlagState.pick.rawValue)
        #expect(asset.flag == .pick)
    }

    @Test @MainActor func importSkipsDuplicatesByPathWithinSession() throws {
        let schema = Schema([PhotoAsset.self, PhotoStack.self, PhotoScene.self, Session.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("shot.cr2")
        try Data([0x00, 0x01]).write(to: fileURL)

        let session = Session(name: "Day 1", folderURL: dir)
        context.insert(session)

        let importer = LibraryImporter()
        let first = try importer.importFiles([fileURL], into: context, session: session)
        let second = try importer.importFiles([fileURL], into: context, session: session)

        #expect(first.count == 1)
        #expect(second.count == 0)
        #expect(try context.fetchCount(FetchDescriptor<PhotoAsset>()) == 1)
    }

    @Test @MainActor func importAllowsSamePathAcrossDifferentSessions() throws {
        let schema = Schema([PhotoAsset.self, PhotoStack.self, PhotoScene.self, Session.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("shot.cr2")
        try Data([0x00, 0x01]).write(to: fileURL)

        let sessionA = Session(name: "Day 1", folderURL: dir)
        let sessionB = Session(name: "Day 2", folderURL: dir)
        context.insert(sessionA)
        context.insert(sessionB)

        let importer = LibraryImporter()
        let first = try importer.importFiles([fileURL], into: context, session: sessionA)
        let second = try importer.importFiles([fileURL], into: context, session: sessionB)

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(try context.fetchCount(FetchDescriptor<PhotoAsset>()) == 2)
    }
}
