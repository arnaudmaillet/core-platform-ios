import CoreModels
import Foundation

/// Warms a post's first page of comments before it is opened (#2002), for
/// every surface that opens a post full screen: the Feed, a profile's grid,
/// the shared post sets (search, hashtags, the place page, a cluster's
/// gallery), the map's pins, the sound sheet, and the openers themselves.
/// What it warms is what the flight's replica and the landed page read
/// synchronously (`cachedTopComments`), so the first comment flies in with
/// the post instead of fading in after the landing.
///
/// ⚠️ TWO QUEUES, AND THE DIFFERENCE IS THE WHOLE FEATURE (the Feed's rule,
/// lifted from `ForYouViewController.warm`):
/// - **`warmNow`** is what the viewer is LOOKING AT: one task per post,
///   started now. Serial is wrong here: the post filling the screen waited
///   behind eleven others down the page and was still fetching at the tap.
/// - **`warmLater`** is a queue that claims an id only when it REACHES it.
///   Claiming a batch up front is how the ahead-of-time pass starved the
///   visible one: it had put its name on every post, so a card coming into
///   view had nothing left to ask for.
///
/// **Nothing is asked twice:** an id already held by the cache, or in
/// flight, is skipped. The cache is the repository's, viewer-scoped, so a
/// viewer change makes every post askable again with no reset here.
///
/// **A queued id belongs to the surface that queued it:** when that surface
/// goes, what it left in the queue is dropped when reached.
@MainActor
public final class PostOpenWarm {
    private let prefetch: @Sendable (PostID) async -> Void
    private let isHeld: (PostID) -> Bool
    private var inFlight: Set<PostID> = []
    private var queue: [(id: PostID, owner: Owner)] = []
    private var isDraining = false

    /// A surface's weak handle on what it queued.
    private struct Owner {
        weak var object: AnyObject?
        let isUnowned: Bool
        var isGone: Bool { !isUnowned && object == nil }
    }

    public init(
        prefetch: @escaping @Sendable (PostID) async -> Void,
        isHeld: @escaping (PostID) -> Bool
    ) {
        self.prefetch = prefetch
        self.isHeld = isHeld
    }

    /// Warms `ids` now, one request each, in parallel.
    public func warmNow(_ ids: [PostID]) {
        for id in ids where claim(id) {
            trace("asking", id)
            Task { await self.run(id) }
        }
    }

    /// Queues `ids` behind what is already queued, one request at a time.
    /// `owner`: the surface queuing them; its ids are dropped once it is
    /// gone. Nil: nothing cancels them.
    public func warmLater(_ ids: [PostID], owner: AnyObject? = nil) {
        let handle = Owner(object: owner, isUnowned: owner == nil)
        let known = Set(queue.map(\.id))
        queue += ids.filter { !known.contains($0) }.map { ($0, handle) }
        drain()
    }

    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        Task {
            while !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                guard !next.owner.isGone, self.claim(next.id) else { continue }
                self.trace("queued", next.id)
                await self.run(next.id)
            }
            self.isDraining = false
        }
    }

    /// Takes `id` if it is neither held nor in flight.
    private func claim(_ id: PostID) -> Bool {
        guard !isHeld(id), !inFlight.contains(id) else { return false }
        inFlight.insert(id)
        return true
    }

    private func run(_ id: PostID) async {
        await prefetch(id)
        inFlight.remove(id)
        trace("ready", id)
    }

    #if DEBUG
    /// What is in flight and queued, for tests.
    var debugInFlight: Set<PostID> { inFlight }
    var debugQueued: [PostID] { queue.map(\.id) }
    #endif

    /// `-warm-log`: what was asked for and when it answered. It tells "the
    /// warm never ran" from "the warm ran and the tap beat it": two failures
    /// that look identical on screen.
    private func trace(_ what: String, _ id: PostID) {
        #if DEBUG
        if Self.traces { print("[warm] \(what) \(id.rawValue)") }
        #endif
    }

    #if DEBUG
    private static let traces = ProcessInfo.processInfo.arguments.contains("-warm-log")
    #endif
}
