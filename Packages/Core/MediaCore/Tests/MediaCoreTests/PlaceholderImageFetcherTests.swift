import Foundation
import Testing
@testable import MediaCore

/// Mock mode's image fetcher serves a bundled photo when the app hands it one,
/// and synthesizes a colour for everything else — the image-side mirror of
/// `PlaceholderVideoFetcher(bundledClip:)`.
struct PlaceholderImageFetcherTests {
    private func temporaryFile(_ bytes: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("placeholder-fetcher-\(UUID().uuidString).jpg")
        try bytes.write(to: file)
        return file
    }

    @Test func aBundledPhotoIsServedAsItsFilesBytes() async throws {
        let bytes = Data("a real jpeg".utf8)
        let file = try temporaryFile(bytes)
        defer { try? FileManager.default.removeItem(at: file) }
        let photo = try #require(URL(string: "mock://photo/gallery-1-01?w=10&h=10"))
        let fetcher = PlaceholderImageFetcher(bundledPhoto: { $0 == photo ? file : nil })

        #expect(try await fetcher.fetchImageData(for: photo) == bytes)
    }

    /// A URL the closure does not claim keeps today's synthesized colour.
    @Test func anUnclaimedURLIsStillSynthesized() async throws {
        let fetcher = PlaceholderImageFetcher(bundledPhoto: { _ in nil })
        let url = try #require(URL(string: "mock://media/3?w=10&h=10"))

        let data = try await fetcher.fetchImageData(for: url)
        let synthesized = try await PlaceholderImageFetcher().fetchImageData(for: url)
        #expect(!data.isEmpty)
        #expect(data.count == synthesized.count)
    }

    /// A claimed file that is gone falls back to the synthesized colour rather
    /// than failing the load.
    @Test func aMissingFileFallsBackToSynthesis() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).jpg")
        let fetcher = PlaceholderImageFetcher(bundledPhoto: { _ in missing })
        let data = try await fetcher.fetchImageData(for: try #require(URL(string: "mock://photo/x?w=8&h=8")))
        #expect(!data.isEmpty)
    }

    /// The colour is the same on every launch: pinned to a value computed
    /// outside the process, which a per-process seeded hash can never match
    /// twice (`mock://avatar/7` has the path "/7").
    @Test func theHueIsTheSameOnEveryLaunch() {
        #expect(PlaceholderImageFetcher.hue(forPath: "/7") == 131.0 / 360)
        #expect(PlaceholderImageFetcher.hue(forPath: "/7") != PlaceholderImageFetcher.hue(forPath: "/8"))
    }
}
