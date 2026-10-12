import Foundation
import Synchronization
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

    /// An indexed cache (the UI assets namespace) is measured and cleared
    /// through itself, never by deleting its folder.
    @Test func indexedCachesAreMeasuredAndClearedThroughThemselves() {
        let held = Mutex<Int64>(700)
        let inventory = MediaCacheInventory(
            locations: { [] }, urlCache: nil,
            indexedBytes: { held.withLock { $0 } },
            clearIndexed: { held.withLock { $0 = 0 } }
        )
        #expect(inventory.size() == 700)
        inventory.clear()
        #expect(inventory.size() == 0)
    }

    @Test func missingLocationsCountForNothing() {
        let inventory = MediaCacheInventory(locations: { [URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")] }, urlCache: nil)
        #expect(inventory.size() == 0)
        inventory.clear()
    }
}
