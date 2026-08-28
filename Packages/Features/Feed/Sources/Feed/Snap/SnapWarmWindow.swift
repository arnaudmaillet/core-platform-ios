import Foundation

/// How far ahead of the viewer the full-screen pager gets ready, and how far
/// behind it stays ready.
///
/// ## Two windows, because the two costs are not the same
///
/// **Content** — the cover to decode, the comment stream to fetch, the caption
/// to lay out — is cheap, bounded, and the thing a viewer notices missing: a
/// page that snaps in and then fills itself in reads as a stutter even when
/// nothing dropped a frame. Short-video feeds prefetch "the next few" for
/// exactly this reason, typically the first chunk of about five upcoming items
/// on the network side. Ours is two ahead: each page here is a FULL-SCREEN
/// image rather than a two-second chunk, so five of them is memory spent on
/// pages most sessions never reach.
///
/// **Players** are not cheap and are not bounded — an `AVPlayer` holds a
/// decoder, and iOS has a hard ceiling on how many can render at once. The
/// shape every short-video feed converges on is THREE: one playing, one either
/// side, rotated as the viewer moves. That is one ahead and one behind, and it
/// is deliberately narrower than the content window.
///
/// ## Why one behind, and only one
///
/// Paging back is a real gesture but a rarer one, and the page behind is the
/// one just left — its cover is still in the image cache and its stream is
/// still in memory. One is enough to make the return instant; two would spend
/// a player slot on a page nobody is heading toward.
enum SnapWarmWindow {
    /// Pages of content kept ready ahead of the active one.
    static let contentAhead = 2
    /// And behind it.
    static let contentBehind = 1
    /// Players kept ready either side — three in total with the active page's,
    /// which is the pool every comparable feed runs.
    static let playersEitherSide = 1

    /// The indices to warm, NEAREST FIRST and ahead before behind.
    ///
    /// Order is not decoration: these are handed to work that runs in sequence
    /// and can be outrun by a fast scroll, so the page the viewer is most
    /// likely to reach next has to be asked for first. A window returned in
    /// index order would warm the page BEHIND before the page ahead whenever
    /// the active page is not the first.
    static func indices(around active: Int, count: Int, ahead: Int, behind: Int) -> [Int] {
        guard count > 0, active >= 0, active < count else { return [] }
        var window: [Int] = []
        // Interleaved by distance so a truncated warm still covers both sides
        // in proportion.
        for step in 1...max(ahead, behind, 1) {
            if step <= ahead, active + step < count { window.append(active + step) }
            if step <= behind, active - step >= 0 { window.append(active - step) }
        }
        return window
    }

    /// The content window: covers, comment streams, anything cheap to hold.
    static func content(around active: Int, count: Int) -> [Int] {
        indices(around: active, count: count, ahead: contentAhead, behind: contentBehind)
    }

    /// The player window: the immediate neighbours, and nothing else.
    static func players(around active: Int, count: Int) -> [Int] {
        indices(around: active, count: count, ahead: playersEitherSide, behind: playersEitherSide)
    }
}
