import CoreModels
import Foundation

/// A paged grid's answer to a full-screen feed opened from one of its tiles
/// (#638): the posts after a given one, as the grid holds them — then, when
/// they run out, the grid's caller's next page.
///
/// One object for every grid that pages (search and hashtag surfaces, For
/// You's lists and Discover gallery), because the hard part is the same in
/// each: the next page is the caller's to fetch, and the feed has to WAIT for
/// its answer without holding its own slot forever.
@MainActor
final class GridFeedContinuation {
    /// The ids the grid holds, in its order.
    private let ids: () -> [PostID]
    /// Whether the caller has another page past them.
    private let hasMore: () -> Bool
    /// Asks the caller for that page — the grid's own near-end cue.
    private let askMore: () -> Void
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many posts a step hands the feed.
    static let window = 12
    /// How long a step waits on the caller before answering "nothing yet" —
    /// a caller that never answers must not hold the feed.
    static let waitLimit: Duration = .seconds(10)

    init(ids: @escaping () -> [PostID], hasMore: @escaping () -> Bool, askMore: @escaping () -> Void) {
        self.ids = ids
        self.hasMore = hasMore
        self.askMore = askMore
    }

    /// The ids after `id`. `nil`: nothing follows and nothing more will.
    /// Empty: none yet (the page failed, or took too long); the feed asks
    /// again on its next approach.
    func postIDs(after id: PostID) async -> [PostID]? {
        for _ in 0..<2 {
            let held = ids()
            guard let index = held.firstIndex(of: id) else { return nil }
            let following = held[(index + 1)...]
            if !following.isEmpty { return Array(following.prefix(Self.window)) }
            guard hasMore() else { return nil }
            askMore()
            await nextAnswer()
        }
        return []
    }

    /// The caller answered — new posts, a page over, or no more: a waiting
    /// feed reads again. Call it with every answer, whatever it says.
    func answered() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    private func nextAnswer() async {
        let limit = Task { [weak self] in
            try? await Task.sleep(for: Self.waitLimit)
            self?.answered()
        }
        await withCheckedContinuation { waiters.append($0) }
        limit.cancel()
    }
}
