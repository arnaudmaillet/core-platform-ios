import AVFoundation
import Foundation
import Testing
import UIKit
@testable import MediaPlayback

struct VideoExporterTests {
    /// A real source clip to export: synthesize one with the placeholder fetcher.
    private func sourceClip() async throws -> URL {
        try await PlaceholderVideoFetcher(durationSeconds: 1.0)
            .playableURL(for: URL(string: "mock://video/exp?w=240&h=320")!)
    }

    @Test func exportProducesAPlayableMp4WithMetadata() async throws {
        let source = try await sourceClip()
        let exported = try await VideoExporter().export(source)

        #expect(FileManager.default.fileExists(atPath: exported.fileURL.path))
        #expect(exported.mimeType == "video/mp4")
        #expect(exported.byteSize > 0)
        #expect(exported.durationSeconds > 0)
        #expect(exported.pixelWidth > 0 && exported.pixelHeight > 0)
        #expect(exported.sha256Hex.count == 64)

        // The export is itself a valid, playable asset.
        let tracks = try await AVURLAsset(url: exported.fileURL).loadTracks(withMediaType: .video)
        #expect(!tracks.isEmpty)
    }

    @Test func posterImageIsGenerated() async throws {
        let source = try await sourceClip()
        let poster = await VideoExporter().posterImage(for: source)
        #expect(poster != nil)
        #expect((poster?.size.width ?? 0) > 0)
    }

    @Test func placeholderFetcherPassesThroughLocalFileURLs() async throws {
        // A local clip must play as-is (optimistic compose insert), not be synthesized over.
        let localClip = try await sourceClip()
        let resolved = try await PlaceholderVideoFetcher().playableURL(for: localClip)
        #expect(resolved == localClip)
    }
}
