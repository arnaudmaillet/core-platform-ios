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
        _ = try await within("step 1: the previous post's picture never came back from the pipeline") {
            try await pipeline.image(for: firstURL)
        }
        #expect(cell.debugShownPhoto == nil, "the previous post's picture landed")

        await fetcher.release(secondURL)
        guard let expected = try await within("step 2: the new post's picture never came back from the pipeline", {
            try await pipeline.image(for: secondURL)
        }) else { return }
        for _ in 0..<Self.looks where cell.debugShownPhoto == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(cell.debugShownPhoto === expected, "step 3: the new post's picture was never drawn")
    }

    /// A look budget, not a deadline. ⚠️ Under a starved Feed lane a look took
    /// ~100 ms, and an unbudgeted await (or 6,000 looks) ran into the 10-minute
    /// `.timeLimit`, which hung the process instead of naming the step that
    /// never resumed. 1,500 looks stay under ~150 s at that rate.
    private static let looks = 1_500

    /// Awaits `operation` under the look budget: a fetch that never resumes
    /// fails here, named, instead of hanging the suite.
    private func within(
        _ step: String, _ operation: @escaping @Sendable () async throws -> UIImage
    ) async throws -> UIImage? {
        let outcome = Outcome()
        let task = Task {
            do { outcome.set(.success(try await operation())) } catch { outcome.set(.failure(error)) }
        }
        for _ in 0..<Self.looks {
            if let result = outcome.result { return try result.get() }
            try? await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        Issue.record("\(step)")
        return nil
    }
}

/// What the watched task ended with, read by the look loop.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<UIImage, any Error>?
    var result: Result<UIImage, any Error>? { lock.withLock { value } }
    func set(_ result: Result<UIImage, any Error>) { lock.withLock { value = result } }
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
