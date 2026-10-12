import CacheKit
import Foundation
import Synchronization
import Testing
import UIKit
@testable import MediaCore

/// Holds every fetch until `open()`, lets a test await the first fetch's
/// start, and records, once let go, the fetching task's priority and the
/// fill priority its context reports (what `URLSessionTask.priority`
/// follows in the app's fetcher).
private final class EscalationFetcher: ImageFetching {
    private struct State {
        var hasBegun = false
        var beganWaiters: [CheckedContinuation<Void, Never>] = []
        var isOpen = false
        var openWaiters: [CheckedContinuation<Void, Never>] = []
        var taskPriority: TaskPriority?
        var fillPriority: CacheFillPriority?
    }

    private let state = Mutex(State())

    var taskPriority: TaskPriority? { state.withLock { $0.taskPriority } }
    var fillPriority: CacheFillPriority? { state.withLock { $0.fillPriority } }

    func began() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let hasBegun = state.withLock { state -> Bool in
                if !state.hasBegun { state.beganWaiters.append(continuation) }
                return state.hasBegun
            }
            if hasBegun { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let taken = state.openWaiters
            state.openWaiters = []
            return taken
        }
        for waiter in waiters { waiter.resume() }
    }

    func fetchImageData(for url: URL) async throws -> Data {
        try await fetchImage(for: url, context: nil).data
    }

    func fetchImage(for url: URL, context: CacheFillContext?) async throws -> ImageFetchResult {
        let starters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.hasBegun = true
            let taken = state.beganWaiters
            state.beganWaiters = []
            return taken
        }
        for waiter in starters { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isOpen = state.withLock { state -> Bool in
                if !state.isOpen { state.openWaiters.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
        state.withLock {
            $0.taskPriority = Task.currentPriority
            $0.fillPriority = context?.priority
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return ImageFetchResult(data: data, isCacheable: true)
    }
}

/// A look budget, not a deadline, for state a test-priority task writes
/// (a visible load joining): never for a prefetch's own fill (#1049).
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<6_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A prefetched image the viewer now waits for is fetched and decoded at
/// user-initiated priority (#1052): the visible load's join escalates the
/// running decode, and the download follows the decode.
struct ImagePriorityEscalationTests {
    @Test func aPrefetchJoinedByAVisibleLoadDownloadsAtUserInitiated() async throws {
        let fetcher = EscalationFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let owner = CacheOwner("grid")
        let url = try #require(URL(string: "mock://photo/escalate-1"))

        let interest = pipeline.prefetch(url, window: .display, owner: owner)
        await fetcher.began()
        #expect(pipeline.downloadPriority(for: url) == .next, "a display prefetch downloads at P1")

        let visible = Task { try await pipeline.image(for: url) }
        #expect(await eventually { pipeline.downloadPriority(for: url) == .visible }, "the visible load raises the download it waits on")
        fetcher.open()
        _ = try await visible.value

        let priority = try #require(fetcher.taskPriority)
        #expect(priority >= .userInitiated, "the running download was escalated (\(priority))")
        #expect(fetcher.fillPriority == .visible, "and its network priority hint raised")
        withExtendedLifetime((owner, interest)) {}
    }

    @Test func aPrefetchNobodyRaisesStillDownloadsAtUtility() async throws {
        let fetcher = EscalationFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let owner = CacheOwner("grid")
        let url = try #require(URL(string: "mock://photo/escalate-2"))

        let interest = pipeline.prefetch(url, window: .display, owner: owner)
        await fetcher.began()
        fetcher.open()
        // Joined at the prefetch's own P1: awaited without raising it.
        _ = try await pipeline.image(for: url, priority: .next)

        #expect(fetcher.taskPriority == .utility, "a prefetch nobody waits for stays at utility")
        #expect(fetcher.fillPriority == .next)
        withExtendedLifetime((owner, interest)) {}
    }
}
