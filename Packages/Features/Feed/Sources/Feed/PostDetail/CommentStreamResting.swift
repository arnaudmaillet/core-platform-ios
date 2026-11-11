import UIKit

/// WHERE A COMMENT STREAM RESTS: one contract of the comments panel (#2287
/// § 3, the owner 2026-11-11), the same in every host the panel sits in —
/// the text page, the media post's comments sheet, the published text
/// post's screen.
///
/// - **`.top` (Popular, a ranking, #2007):** at rest, its first row — the
///   post's caption — right under the room's top. A short one leaves its
///   room below.
/// - **`.bottom` (Recent, a conversation, #1799):** at rest, its last
///   comment right over the room's bottom — the composer. A short one leaves
///   its room above (the slack, worn on top of the room's top,
///   `StreamBottomAnchor`); a long one opens at its end, and older pages
///   land above it without moving what is on screen.
///
/// ⚠️ THE HOSTS NEVER DECIDE IT. They give the room — the inset under their
/// bar and the one over their composer
/// (`PostDetailViewController.setEngagedInsets`) — and the stream rests in
/// it as its kind says. Until #2287 each host set parts of it (the sheet
/// kept the anchor "left on", the text page its own clearances), so the rule
/// could drift by host, and nothing checked that the two put a tab at the
/// same place (`CommentStreamRestingTests` does now).
enum CommentStreamResting: Equatable {
    case top
    case bottom

    /// The kind's resting place: Popular at its top, Recent at its bottom.
    init(_ kind: CommentStream.Kind) {
        switch kind {
        case .popular: self = .top
        case .recent: self = .bottom
        }
    }

    /// Whether a stream shorter than its room is anchored to the room's
    /// bottom, the room left worn above it.
    var anchorsShortStream: Bool { self == .bottom }

    /// Whether the stream keeps its resting end as its content changes, until
    /// the reader scrolls away from it. A top is kept by UIKit itself (the
    /// offset holds); an end is pinned (`CommentStream.keepRestingEnd`).
    var pinsItsEnd: Bool { self == .bottom }

    /// The room a short stream leaves above its rows, worn in its top inset:
    /// none at the top.
    func slack(room: CGFloat, contentHeight: CGFloat) -> CGFloat {
        anchorsShortStream ? StreamBottomAnchor.slack(viewport: room, contentHeight: contentHeight) : 0
    }

    /// The offset a stream of `contentHeight` rests at in a list
    /// `boundsHeight` tall, its insets (the slack and what is drawn behind
    /// the chrome included) `insets`.
    func restingOffset(contentHeight: CGFloat, boundsHeight: CGFloat, insets: UIEdgeInsets) -> CGFloat {
        let top = -insets.top
        switch self {
        case .top: return top
        case .bottom: return max(top, contentHeight + insets.bottom - boundsHeight)
        }
    }

    /// The offset `list` rests at.
    func restingOffset(of list: UIScrollView) -> CGFloat {
        restingOffset(
            contentHeight: list.contentSize.height, boundsHeight: list.bounds.height,
            insets: list.adjustedContentInset
        )
    }
}
