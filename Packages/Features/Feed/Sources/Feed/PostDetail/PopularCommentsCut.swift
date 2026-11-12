import CoreGraphics

/// POPULAR, CUT TO ITS ROOM (#2298, the owner 2026-11-11): on the text page
/// and in the comments sheet, Popular shows the caption, then as many WHOLE
/// threads as fit the room between the bar and the composer, then stops —
/// its last row "See all n comments" turning to Recent whenever there is
/// more than it shows. It is not paged: the server's first ranked page is
/// all it reads.
///
/// - **A thread** is the way it stands at rest: a top-level comment with its
///   reply fold (`CommentThreadPresentation`, nothing expanded).
/// - **When everything fits** and the server holds no more, there is no
///   "See all": the stream doesn't scroll.
/// - **Never zero:** the first thread always shows, even when the caption
///   with it is taller than the room. That is the one case where the page
///   scrolls, because the caption is never truncated (the owner,
///   2026-11-02): caption, first thread, "See all".
///
/// Pure arithmetic on measured heights, for tests: the room, the lead (the
/// caption) and the threads are measured per device and per text size by
/// the stream (`CommentStream.cutPopular`).
struct PopularCommentsCut: Equatable {
    /// How many threads show, from Popular's top.
    let shownThreads: Int
    /// Whether "See all n comments" ends the stream.
    let showsSeeAll: Bool

    /// Half a point of rounding is still a fit: the heights are measured
    /// through real cells, and a thread a fraction too tall is not a thread
    /// that doesn't fit.
    static let tolerance: CGFloat = 0.5

    /// - Parameters:
    ///   - threadHeights: each thread's height at rest, in Popular's order.
    ///   - room: the stream's room, its section insets taken off.
    ///   - lead: what stands above the threads (the caption row).
    ///   - seeAllHeight: the "See all" row's height.
    ///   - sourceHasMore: whether the server holds another ranked page.
    init(threadHeights: [CGFloat], room: CGFloat, lead: CGFloat, seeAllHeight: CGFloat, sourceHasMore: Bool) {
        guard !threadHeights.isEmpty else {
            shownThreads = 0
            showsSeeAll = false
            return
        }
        // Everything, with nothing behind it: no "See all", no scroll.
        let whole = lead + threadHeights.reduce(0, +)
        if !sourceHasMore, whole <= room + Self.tolerance {
            shownThreads = threadHeights.count
            showsSeeAll = false
            return
        }
        // Otherwise "See all" stands last, and its room is kept for it.
        var used = lead + seeAllHeight
        var count = 0
        for height in threadHeights {
            guard used + height <= room + Self.tolerance else { break }
            used += height
            count += 1
        }
        shownThreads = max(1, count)
        showsSeeAll = shownThreads < threadHeights.count || sourceHasMore
    }

    /// `items` cut into threads, in order: a top-level comment starts one,
    /// and its replies and folds follow it. Items before any top-level
    /// comment (a page that starts mid-thread) make one leading thread.
    static func threads<Item>(of items: [Item], startsThread: (Item) -> Bool) -> [[Item]] {
        var threads: [[Item]] = []
        for item in items {
            if startsThread(item) || threads.isEmpty {
                threads.append([item])
            } else {
                threads[threads.count - 1].append(item)
            }
        }
        return threads
    }
}
