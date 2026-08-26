import Foundation

/// Which of a collection's clips keep a player while the viewer is on one page.
///
/// ## Why a window and not one per clip
///
/// The obvious answer to "paging back to a clip shows its thumbnail again" is
/// to give every clip in the post its own player and never let one go. It is
/// the right instinct — a paused player keeps its last frame and its playhead,
/// and returning to it costs nothing — but the quantity is wrong in a way that
/// only shows up on the galleries that need it most.
///
/// A player is not free and the ceiling that bites is not memory: simultaneous
/// hardware decode sessions are a small number on every phone this ships to,
/// and the seventh clip does not degrade politely — it starves one of the six
/// already running. A gallery of twelve clips asking for twelve players is
/// asking for a stutter it cannot see coming, and it takes the budget from the
/// feed around it besides.
///
/// So the retention is bounded by what the pool says it can carry, and spent on
/// the clips the viewer can reach in one gesture: the current page, then its
/// nearest neighbours outward. That buys the whole of the reported benefit —
/// swipe away and back and the picture is exactly where it was — for a cost
/// that does not grow with the size of the gallery.
///
/// ## Why forward wins a tie
///
/// At equal distance the page AHEAD is kept before the one behind. Carousels
/// are read forwards; the next clip is the one most likely to be asked for, and
/// on an odd budget somebody has to lose. Ties are broken deterministically for
/// the same reason the choice is a pure function at all — a retention policy
/// that shuffles under equal input cannot be tested, and this one is asserted
/// page by page in `CarouselRetentionWindowTests`.
public enum CarouselRetentionWindow {
    /// The pages that should be holding a player, nearest first.
    ///
    /// - Parameters:
    ///   - videoPages: indices of the pages with a stream, in page order.
    ///     Stills are not candidates and never consume budget.
    ///   - currentPage: the page being looked at. It need not be a video page —
    ///     a viewer parked on a photograph between two clips keeps both warm.
    ///   - capacity: how many players may be held, from `VideoPlaybackController`.
    ///
    /// - Returns: at most `capacity` page indices, ordered by how soon the
    ///   viewer could reach them. The order is part of the contract: a caller
    ///   short of budget drops from the END.
    public static func pagesToRetain(
        videoPages: [Int], currentPage: Int, capacity: Int
    ) -> [Int] {
        guard capacity > 0 else { return [] }
        return ranked(videoPages: videoPages, currentPage: currentPage)
            .prefix(capacity)
            .map { $0 }
    }

    /// How many clips are brought to their first frame BEFORE the viewer
    /// reaches them.
    ///
    /// ⚠️ SMALLER THAN THE RETENTION WINDOW, and the two must not be confused.
    ///
    /// Retention keeps a decode that has already been paid for: the clip ran,
    /// so holding it costs a decoder and nothing else. Prewarming starts a NEW
    /// one — a stream to open, segments to fetch, a pipeline to fill — and it
    /// does so while the clip the viewer is actually watching is starting.
    /// Warming the whole window would mean six streams competing for bandwidth
    /// with the only one on screen, which trades a delay the viewer might never
    /// have met for a stutter in the one they are certainly looking at.
    ///
    /// Two: the page ahead and the page behind, which is everything reachable
    /// by a single swipe. Beyond that the viewer has travelled, and a fresh
    /// start is a fair price for a journey.
    public static let prewarmDepth = 2

    /// The clips worth preparing ahead of the viewer, nearest first, excluding
    /// the one being watched — the caller is already starting that one.
    public static func pagesToPrewarm(
        videoPages: [Int], currentPage: Int, budget: Int
    ) -> [Int] {
        guard budget > 0 else { return [] }
        return ranked(videoPages: videoPages, currentPage: currentPage)
            .filter { $0 != currentPage }
            .prefix(min(budget, prewarmDepth))
            .map { $0 }
    }

    /// The shared ordering: by reach, then forward, then by page.
    private static func ranked(videoPages: [Int], currentPage: Int) -> [Int] {
        let ranked = videoPages.sorted { lhs, rhs in
            let (near, far) = (abs(lhs - currentPage), abs(rhs - currentPage))
            if near != far { return near < far }
            // Equal distance: the one ahead of the viewer, then by page order so
            // the result never depends on the input's arrangement.
            let (leadingLHS, leadingRHS) = (lhs >= currentPage, rhs >= currentPage)
            if leadingLHS != leadingRHS { return leadingLHS }
            return lhs < rhs
        }
        return ranked
    }
}
