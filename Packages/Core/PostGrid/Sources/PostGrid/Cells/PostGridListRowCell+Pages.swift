import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// The media's pages, and the test hooks that press a row's controls
extension PostGridListRowCell {
    #if DEBUG
    /// Presses the comment count the row is ACTUALLY wearing.
    ///
    /// The point of asking the row rather than naming a chip: a card shows the
    /// overlay pair over its media and the closing line's pair when it has
    /// none, and wiring only one of the two is a defect that no test naming the
    /// other would ever see.
    public func debugTapCommentsChip() -> Bool {
        Self.debugPress(commentsAction)
    }

    /// Presses the like chip — a stake of the tap amount, when wired.
    public func debugTapLikesChip() -> Bool {
        Self.debugPress(likesAction)
    }

    /// Presses `action` as a finger would, reporting whether it is a control
    /// that is shown — "did nothing" and "is not a control" differ.
    private static func debugPress(_ action: AppControl) -> Bool {
        guard !action.isHidden, action.isUserInteractionEnabled, action.superviewChainIsVisible,
              action.acceptsTaps else { return false }
        action.debugTap()
        return true
    }
    #endif

    /// Moves this row's carousel, e.g. to follow the page an opened post is on.
    /// Ignored by a row with no collection.
    public func setMediaPage(_ page: Int, animated: Bool = true) {
        guard let carousel, !carousel.isHidden else { return }
        carousel.setPage(page, animated: animated)
    }

    /// Which page of this row's carousel is showing, or nil for a row with no
    /// collection. A hero flight departs from this page, so whatever opens the
    /// post has to land on it.
    public var currentMediaPage: Int? {
        guard let carousel, !carousel.isHidden else { return nil }
        return carousel.currentPage
    }

    /// Whether this row's carousel can still travel `delta` pages — the cell's
    /// twin of `MediaCarouselView.hasTravel(towardsPageDelta:)`, for a host that
    /// holds cells rather than carousels.
    ///
    /// ⚠️ A row with no collection answers `false`, not nil, and the difference
    /// matters at the only kind of call site there is: a gesture gate. `false`
    /// reads as "nothing here wants this drag", which is the truth for a text
    /// row and for a single photograph — an optional would make every caller
    /// invent that answer for itself, and the first one to invent `true` would
    /// hand the drag to a carousel that does not exist.
    public func mediaHasTravel(towardsPageDelta delta: Int) -> Bool {
        guard let carousel, !carousel.isHidden else { return false }
        return carousel.hasTravel(towardsPageDelta: delta)
    }

    #if DEBUG
    /// Scrolls this row's carousel, or false if it has none.
    @discardableResult
    public func debugScrollCarousel(toPage index: Int, animated: Bool = true) -> Bool {
        guard let carousel, !carousel.isHidden else { return false }
        return carousel.debugScroll(toPage: index, animated: animated)
    }

    /// Presses "Show more". Returns false when there was nothing to reveal,
    /// which is the answer a harness must not mistake for success.
    ///
    /// The simulator injects no touches, so this is the only way this control
    /// is reachable in an automated run.
    @discardableResult
    public func debugTapShowMore() -> Bool {
        guard showMoreRange != nil else { return false }
        revealTapped()
        return true
    }

    /// The caption as drawn: its line cap, how it ends a cut line, its text,
    /// and where it and the closing line sit in this cell's space — what a
    /// FIXED-height card (`fixedCaptionLines`) is pinned by.
    public var debugCaptionLineLimit: Int { captionLabel.numberOfLines }
    public var debugCaptionLineBreakMode: NSLineBreakMode { captionLabel.lineBreakMode }
    public var debugCaptionText: String? { captionLabel.attributedText?.string ?? captionLabel.text }
    public var debugShowsMoreAffordance: Bool { showMoreRange != nil }
    public var debugCaptionFrame: CGRect { captionLabel.convert(captionLabel.bounds, to: self) }
    public var debugClosingLineFrame: CGRect {
        metaRow.isHidden ? .null : metaRow.convert(metaRow.bounds, to: self)
    }
    #endif
}
