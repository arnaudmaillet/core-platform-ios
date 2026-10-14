import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A full-screen page's photograph on the loading rules (#1088): a page
/// reconfigured for another post never draws the previous post's picture,
/// however late it lands.
@MainActor
struct SnapCoverLoadTests {
    private func photo(_ id: String) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("p"), authorName: "Ava",
            metaText: "@ava · 3m", avatarURL: nil, caption: "caption",
            mediaURL: URL(string: "https://example.test/\(id).jpg"), mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 0, timestampText: "now"
        )
    }

    /// ⚠️ The old post's picture lands after the page moved on: it lands
    /// nowhere, and the new post's picture is the one drawn.
    @Test(.timeLimit(.minutes(10)))
    func aLatePictureForThePreviousPostLandsNowhere() async throws {
        let fetcher = HeldFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let cell = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let first = photo("snap-a"), second = photo("snap-b")
        cell.configure(with: first, pipeline: pipeline, videoPlayback: nil)
        cell.configure(with: second, pipeline: pipeline, videoPlayback: nil)

        let firstURL = try #require(first.mediaURL), secondURL = try #require(second.mediaURL)
        await fetcher.release(firstURL)
        _ = try await pipeline.image(for: firstURL)
        #expect(cell.debugShownPhoto == nil, "the previous post's picture landed")

        await fetcher.release(secondURL)
        let expected = try await pipeline.image(for: secondURL)
        for _ in 0..<6_000 where cell.debugShownPhoto == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(cell.debugShownPhoto === expected)
    }
}

/// Holds each URL's fetch until the test releases it.
private actor HeldFetcher: ImageFetching {
    private var released: Set<URL> = []
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func release(_ url: URL) {
        released.insert(url)
        waiters.removeValue(forKey: url)?.forEach { $0.resume() }
    }

    func fetchImageData(for url: URL) async throws -> Data {
        if !released.contains(url) {
            await withCheckedContinuation { waiters[url, default: []].append($0) }
        }
        return Self.onePixelPNG
    }

    static let onePixelPNG = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
}
