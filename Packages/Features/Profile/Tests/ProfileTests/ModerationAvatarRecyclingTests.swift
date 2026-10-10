import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Profile

/// The moderation lists' avatars after a fast scroll (#780): Muted, Blocked,
/// Restricted and Follow Requests all load a row's picture through
/// `RowAvatarLoads`, so a cell recycled from one person to the next never
/// wears the previous person's face — including a next person who has no
/// picture at all and keeps their initials.
///
/// The fetcher holds each picture until the test lets it go, so which load
/// lands first is arranged, never raced against a clock.
@MainActor
struct ModerationAvatarRecyclingTests {
    // Ten minutes, not one: CI starves this package, and a 1-minute limit fired there.
    @Test(.timeLimit(.minutes(10)))
    func aRecycledModerationRowNeverShowsThePreviousPersonsAvatar() async throws {
        let fetcher = GatedAvatarFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let ada = try #require(URL(string: "mock://avatar/ada"))
        let grace = try #require(URL(string: "mock://avatar/grace"))
        let loads = RowAvatarLoads()
        let recycled = PersonListCell(frame: .zero), recycledToNoPicture = PersonListCell(frame: .zero)
        let onRecycled = LandedAvatars(), onNoPicture = LandedAvatars()

        // Both cells were showing Ada. One is recycled for Grace, the other for
        // someone with no avatar, before Ada's picture came.
        loads.load(ada, using: pipeline, for: recycled) { onRecycled.land($0) }
        loads.load(ada, using: pipeline, for: recycledToNoPicture) { onNoPicture.land($0) }
        loads.load(grace, using: pipeline, for: recycled) { onRecycled.land($0) }
        loads.load(nil, using: pipeline, for: recycledToNoPicture) { onNoPicture.land($0) }

        // Ada's picture arrives first — late, for rows that have moved on.
        await fetcher.release(ada)
        _ = try await pipeline.image(for: ada)
        await onRecycled.next { await fetcher.release(grace) }

        #expect(onRecycled.images.count == 1)
        #expect(onRecycled.images.first === pipeline.cachedImage(for: grace))
        #expect(onNoPicture.images.isEmpty)
    }
}

/// Records the pictures a row was given, and lets a test wait for the next.
@MainActor
private final class LandedAvatars {
    private(set) var images: [UIImage] = []
    private var waiter: CheckedContinuation<Void, Never>?

    func land(_ image: UIImage) {
        images.append(image)
        waiter?.resume()
        waiter = nil
    }

    /// Runs `trigger`, then returns once the next picture has landed.
    func next(_ trigger: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            Task { await trigger() }
        }
    }
}

/// Holds each URL's fetch until the test releases it.
private actor GatedAvatarFetcher: ImageFetching {
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

    /// The smallest thing `CGImageSourceCreateThumbnailAtIndex` will decode.
    private static let onePixelPNG = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
}
