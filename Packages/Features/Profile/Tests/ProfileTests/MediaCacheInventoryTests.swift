import Foundation
import Testing
@testable import Profile

/// Settings → App Preferences → Storage (#409): the media cache is measured
/// and cleared by what it OWNS, never by directory.
struct MediaCacheInventoryTests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func measuresAndClearsOnlyItsOwnLocations() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = root.appendingPathComponent("fixture-v2-1.mp4")
        let emotes = root.appendingPathComponent("EmoteKit", isDirectory: true)
        let draft = root.appendingPathComponent("UploadCaptures-draft.mov")
        try Data(count: 1_000).write(to: clip)
        try FileManager.default.createDirectory(at: emotes, withIntermediateDirectories: true)
        try Data(count: 500).write(to: emotes.appendingPathComponent("sheet.png"))
        try Data(count: 2_000).write(to: draft)

        let inventory = MediaCacheInventory(locations: { [clip, emotes] }, urlCache: nil)
        #expect(inventory.size() == 1_500)
        inventory.clear()
        #expect(inventory.size() == 0)
        #expect(FileManager.default.fileExists(atPath: draft.path), "a file it doesn't own must survive")
    }

    @Test func missingLocationsCountForNothing() {
        let inventory = MediaCacheInventory(locations: { [URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")] }, urlCache: nil)
        #expect(inventory.size() == 0)
        inventory.clear()
    }
}
