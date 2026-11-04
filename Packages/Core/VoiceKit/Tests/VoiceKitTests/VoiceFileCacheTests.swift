import CacheKit
import Foundation
import Testing
@testable import VoiceKit

/// Voice audio on disk, by asset id (#2101).
struct VoiceFileCacheTests {
    @Test func aKeptTakeIsFoundByItsAsset() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "voice-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try VoiceFileCache.open(root: root)
        #expect(cache.fileURL(forAsset: "asset-1") == nil)
        let take = FileManager.default.temporaryDirectory.appending(path: "take-\(UUID().uuidString).m4a")
        try Data([1, 2, 3]).write(to: take)
        let kept = try #require(try cache.keep(fileAt: take, forAsset: "asset-1"))
        #expect(kept.pathExtension == "m4a", "AVPlayer reads a file's type from its extension")
        #expect(try Data(contentsOf: kept) == Data([1, 2, 3]))
        #expect(!FileManager.default.fileExists(atPath: take.path), "the take was copied, not moved")
        #expect(VoiceFileCache.namespace.scope == .signed)
    }
}
