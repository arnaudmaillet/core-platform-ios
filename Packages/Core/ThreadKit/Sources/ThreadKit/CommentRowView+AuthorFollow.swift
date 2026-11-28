import PostGrid
import UIKit

/// A TEXT PAGE'S CAPTION ROW CARRIES THE AUTHOR'S FOLLOW (#2419, the owner's
/// option A of 2026-11-28): on the name line, just left of the ♥ count.
///
/// ```
///  (◯) Ava Moreau · 2h ———————— (Follow) ♥ 271
///      Weekend build log: rebuilt the pipeline…
/// ```
///
/// The band's Follow (`AuthorFollowButton`) at its compact size, so the
/// same offers, words, confirmation and fold: Follow, Follow back, Requested
/// (quiet, a menu to cancel), "✓ Following" for a moment then the fold, the
/// name getting the room back. Its height is the name's
/// (`CommentRowView.buildLayout`): the line never grows while it shows, and
/// the caption under it never moves. The name truncates first.
///
/// The row draws what its host says (`setAuthorFollowOffer`); the host
/// follows (`onAuthorFollowTapped`). A comment's row has no Follow: every
/// call here is a no-op there.
extension CommentRowView {
    /// The Follow drawn now; `.none` on a comment's row.
    public var authorFollowOffer: AuthorFollowOffer { authorFollowButton?.offer ?? .none }

    /// Draws `offer` on the caption's line: animated when the change is seen
    /// on screen (the button coming in, "✓ Following" then the fold), at
    /// once otherwise (a row filled afresh).
    public func setAuthorFollowOffer(_ offer: AuthorFollowOffer, animated: Bool) {
        authorFollowButton?.show(offer, animated: animated)
    }

    /// Told on a tap on Follow or Follow back: the host follows, through the
    /// shared follow. The row cannot see the follow.
    public var onAuthorFollowTapped: (() -> Void)? {
        get { authorFollowButton?.onFollow }
        set { authorFollowButton?.onFollow = newValue }
    }

    /// Told when the viewer cancels their request from Requested's menu.
    public var onAuthorCancelFollowRequest: (() -> Void)? {
        get { authorFollowButton?.onCancelRequest }
        set { authorFollowButton?.onCancelRequest = newValue }
    }

    /// Forgets the previous post's Follow and its handlers: a recycled row.
    func resetAuthorFollow() {
        onAuthorFollowTapped = nil
        onAuthorCancelFollowRequest = nil
        setAuthorFollowOffer(.none, animated: false)
    }

    #if DEBUG
    /// The caption's Follow, nil on a comment's row. Tests.
    public var debugAuthorFollowButton: AuthorFollowButton? { authorFollowButton }
    #endif
}
