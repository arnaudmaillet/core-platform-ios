import DesignSystem
import Foundation
import Synchronization
import MediaCore
import Testing
import UIKit
@testable import Search

/// The Users tab's avatars after a fast scroll (#780): a cell recycled from
/// one person to the next must never wear the previous person's face, however
/// late that face arrives.
///
/// The fetcher holds each picture until the test lets it go, so which load
/// lands first is arranged, never raced against a clock.
@MainActor
struct SearchPeopleAvatarRecyclingTests {
    // Ten minutes, not one: CI starves this package, and a 1-minute limit
    // fired there. The waits below are bounded in looks and fail first.
    @Test(.timeLimit(.minutes(10)))
    func aRecycledCellNeverShowsThePreviousPersonsAvatar() async throws {
        let fetcher = GatedAvatarFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let ada = try #require(URL(string: "mock://avatar/ada"))
        let grace = try #require(URL(string: "mock://avatar/grace"))
        let loads = RowImageLoads(size: .avatar)
        let cell = PersonListCell(frame: .zero)
        let landed = LandedAvatars()

        // Configured for Ada, then recycled for Grace before Ada's picture came.
        loads.load(ada, using: pipeline, for: cell) { image, _ in landed.land(image) }
        loads.load(grace, using: pipeline, for: cell) { image, _ in landed.land(image) }

        // Ada's picture arrives first — late, for a row that has moved on.
        // ⚠️ RELEASED SYNCHRONOUSLY (#1606): the release used to be an ACTOR
        // call — a hop onto Swift's shared cooperative pool, unbounded. Timed
        // under load (2026-10-23), that hop alone took 0.5–2.9 s while the
        // decode it unblocked took 0.15 s; a pool exhausted by blocking work
        // elsewhere in the process never runs it, and the test sat its 600 s
        // limit with nothing to say. The only waits left are the bounded ones
        // below.
        fetcher.release(ada)
        // ⚠️ BOUNDED, AND SAYING WHICH STAGE STALLED (#1606): this test hung
        // its 600 s limit twice on CI with nothing to say where. Each wait
        // now counts LOOKS (the runner's starvation spends none of them —
        // `settle(until:)`'s rule), and a stage that never answers fails
        // here, at its own line, in well under a minute of work.
        let adaFetched = Flag()
        Task.detached { if (try? await pipeline.image(for: ada)) != nil { adaFetched.set() } }
        try #require(await Self.settle { adaFetched.isSet },
                     "STALLED: Ada's late picture never decoded (the fetcher released it)")
        #expect(landed.images.isEmpty, "Ada's late picture landed on a row that had moved on")

        fetcher.release(grace)
        try #require(await Self.settle { !landed.images.isEmpty },
                     "STALLED: Grace's picture was released but never landed on the row")

        #expect(landed.images.count == 1)
        #expect(landed.images.first === pipeline.cachedImage(for: grace, size: .avatar))
    }

    /// Waits for STATE, in looks (3,000 × 10 ms), never wall-clock time: a
    /// starved runner spends none of the budget.
    private static func settle(until condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<3_000 {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// A flag a detached task raises.
private final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

/// Records the pictures a row was given.
@MainActor
private final class LandedAvatars {
    private(set) var images: [UIImage] = []

    func land(_ image: UIImage) {
        images.append(image)
    }
}

/// Holds each URL's fetch until the test releases it. A lock, not an actor:
/// the test releases without a hop onto the cooperative pool (#1606).
private final class GatedAvatarFetcher: ImageFetching, Sendable {
    private struct Gate {
        var released: Set<URL> = []
        var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let gate = Mutex(Gate())

    func release(_ url: URL) {
        let waiting = gate.withLock { gate in
            gate.released.insert(url)
            return gate.waiters.removeValue(forKey: url) ?? []
        }
        waiting.forEach { $0.resume() }
    }

    func fetchImageData(for url: URL) async throws -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isReleased = gate.withLock { gate in
                guard gate.released.contains(url) else {
                    gate.waiters[url, default: []].append(continuation)
                    return false
                }
                return true
            }
            if isReleased { continuation.resume() }
        }
        return Self.onePixelPNG
    }

    /// The smallest thing `CGImageSourceCreateThumbnailAtIndex` will decode.
    private static let onePixelPNG = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
}
