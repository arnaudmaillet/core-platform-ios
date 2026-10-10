import CoreGraphics
import CoreModels

/// The author pill under the pager's scroll: which page it draws and how
/// blurred it is, decided frame by frame from plain numbers. The screen
/// forwards its scroll callbacks here and applies each `Step` to the pill
/// (`SnapAuthorIdentityView.setScrubBlur`, `showAuthor`).
///
/// The pills follow the FINGER from one post to the next (asked
/// 2026-09-30): they start blurring once the page being left is 30% off
/// screen, change to the incoming post's author and sound when it covers
/// more than half, and sharpen again as it reaches 70% — every step read
/// off the scroll offset, so a held finger holds the blur and a drag back
/// plays it backwards. It used to be a timed blur at the SETTLE, after the
/// page had already arrived. The curve and the swap's hysteresis are
/// `BarPillScrub`'s.
///
/// Runs on every scroll callback, so the frame's work is an offset, a
/// cached comparison and two alphas per pill; the blurred stills are
/// rendered only when a scrub begins and at the swap
/// (`BarItemContentTransition.setScrubBlur`). Programmatic paging (an
/// animated `setContentOffset`, `-snap-fling`) comes through the same
/// callback, so it scrubs the same way.
///
/// A pill whose two pages draw the SAME content (one person's posts, one
/// song) is left sharp. Nothing scrubs while a presentation owns the bars
/// (the screen's `canAnimateBarItems`): the flight's landing settles the
/// pills, as before.
///
/// Kept free of UIKit so the steps are unit-tested without a scroll view
/// (`SnapPillScrubControllerTests`).
struct SnapPillScrubController {
    /// What the pill does on one scroll frame.
    struct Step: Equatable {
        /// The pager's offset in pages.
        var position: CGFloat
        /// 0 (sharp) … 1 (fully blurred) — 0 whenever the two pages draw
        /// the same pill.
        var blur: CGFloat
        /// The page whose content the pill switches to on this frame, if
        /// it has just changed hands.
        var swapTo: Int?
    }

    /// Which page the pills draw, as the SCROLL has it — see `BarPillScrub`.
    private var scrub = BarPillScrub()
    /// The pair of pages the pills' blur was last decided for, and whether
    /// the author pill draws the two differently — asked once per pair, not
    /// per frame.
    private var pair: (upper: Int, differs: Bool)?

    /// The page the pills now draw — a settle put its content there.
    var shownIndex: Int? { scrub.shownIndex }

    /// A page has settled and the pills draw it.
    mutating func settle(at index: Int?) {
        scrub.settle(at: index)
        pair = nil
    }

    /// Forgets the cached "do these two pages differ": a model, or a follow
    /// badge, may have changed what a pair draws (#627). A drag about to
    /// begin and a scrub ending forget it too.
    mutating func forgetPair() {
        pair = nil
    }

    /// One scroll frame. Nil when the pill may not scrub now — no page
    /// height yet, or a presentation owns the bars — and the screen ends
    /// the scrub instead.
    ///
    /// `pillDiffers(upper)` says whether the author pill draws pages `upper`
    /// and `upper + 1` differently; nil is UNKNOWN (a page without its model
    /// yet), which reads as "no" — the pill stays sharp and the settle
    /// blurs it across on the clock once the page has arrived — and is
    /// asked again on the next frame.
    mutating func update(
        offset: CGFloat,
        pageHeight: CGFloat,
        itemCount: Int,
        canScrub: Bool,
        pillDiffers: (Int) -> Bool?
    ) -> Step? {
        guard pageHeight > 0, canScrub else { return nil }
        let position = offset / pageHeight
        let frame = BarPillScrub.frame(position: position, itemCount: itemCount)
        let differs = frame.map { differs(upper: $0.upper, ask: pillDiffers) } ?? false
        let blur = differs ? (frame?.blur ?? 0) : 0
        let swapTo = scrub.update(position: position, itemCount: itemCount)
        return Step(position: position, blur: blur, swapTo: swapTo)
    }

    private mutating func differs(upper: Int, ask: (Int) -> Bool?) -> Bool {
        if let pair, pair.upper == upper { return pair.differs }
        guard let differs = ask(upper) else { return false }
        pair = (upper, differs)
        return differs
    }

    /// Whether the author pill draws `first` and `second` differently: what
    /// it DRAWS is the face, the name, the meta line (the post's age) and
    /// the follow badge.
    static func authorPillDiffers(
        _ first: FeedItemDisplayModel,
        _ second: FeedItemDisplayModel,
        badge: (ProfileID?) -> SnapAuthorIdentityView.FollowBadge
    ) -> Bool {
        first.authorID != second.authorID
            || first.authorName != second.authorName
            || first.avatarURL != second.avatarURL
            || first.metaText != second.metaText
            || badge(first.authorID) != badge(second.authorID)
    }
}
