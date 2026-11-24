import CoreNetworking
import DesignSystem
import Foundation
import ThreadKit
import UIKit

/// The comment streams' fixed values (#2523): the notices' words, the
/// landing's and the reveal's timings, the cell's row, and the empty,
/// draft, failed and taking-longer pages' copy. Out of
/// `PostDetailViewController`, under the same names
/// (`PostDetailViewController.boneFade`…), which `CommentStream` and the
/// tests read.
extension PostDetailViewController {
    /// A held comment's review that didn't go: it is still held.
    static func reviewFailureNotice(approve: Bool) -> (title: String, message: String) {
        (
            approve ? "Couldn't Approve Comment" : "Couldn't Decline Comment",
            "The comment is still held for your review. Try again in a moment."
        )
    }

    static func commentFailureNotice(refused: Bool) -> (title: String, message: String) {
        refused
            ? ("Comments Are Limited", "The author only takes comments from some people.")
            : ("Couldn't Comment", "Your comment wasn't sent. Your text is still here, so you can try again.")
    }

    // MARK: - Landing the viewer's comment (#921)

    /// The longest a landing waits for its scroll to say it ended: UIKit's
    /// animated scroll takes about 0.3 s, and it says nothing when a drag
    /// interrupts it.
    static let landingScrollTimeout: TimeInterval = 0.6
    /// The room a landing slot needs on screen to count as visible: about one
    /// short comment row.
    static let landingRowAllowance: CGFloat = 72

    /// The comment row a stream cell carries, whichever cell it is.
    static func commentRow(in cell: UICollectionViewCell) -> CommentRowView? {
        (cell as? CommentCell)?.row ?? (cell as? ThreadRowCell)?.row
    }

    // MARK: - Stream data source

    /// How long the bones take to step aside.
    static let boneFade: TimeInterval = 0.2
    /// The first row starts as the bones are half gone; each next one a beat
    /// later, up to `revealStaggerCap` rows — past that the tail arrives
    /// together rather than trickling in for a second.
    static let revealLead: TimeInterval = 0.08
    static let revealStagger: TimeInterval = 0.045
    static let revealStaggerCap = 8
    /// A rise of a few points and a hair of scale: the row settles INTO its
    /// place rather than appearing on it. Small on purpose — a list, not a
    /// stage entrance.
    static let revealRise: CGFloat = 10
    static let revealScale: CGFloat = 0.97

    /// Whether a stream apply may animate. A cold apply never does (nothing
    /// to animate from), and neither does the one that introduces the
    /// CAPTION row — see `configure` for why a faded-in glass bubble reads
    /// as a dark-mode flash. Pure, so the rule is testable on its own.
    static func animatesStreamApply(hasAppliedStream: Bool, introducesCaption: Bool) -> Bool {
        hasAppliedStream && !introducesCaption
    }

    static let nearEndRowCount = 5

    /// The empty stream's words: an invitation to write while this is a
    /// DRAFT. A post with no comments shows no page at all (#2477): an empty
    /// list above the composer.
    typealias EmptyPageCopy = CommentsEmptyPageCopy

    static let draftEmptyPageCopy = EmptyPageCopy(
        symbol: "square.and.pencil",
        title: "Start your post",
        subtitle: "Your first message becomes the post."
    )

    /// The first page of comments failed with nothing on screen (#798). The
    /// SAME row as the empty page — same fit, same place — in other words,
    /// because what the reader needs is the reason the stream is empty, and
    /// the way out of it.
    static func commentsFailedPageCopy(_ message: String) -> EmptyPageCopy {
        EmptyPageCopy(
            symbol: "exclamationmark.triangle",
            title: commentsFailureTitle(message),
            subtitle: "Check your connection and try again.",
            actionTitle: "Try Again"
        )
    }

    /// The first page past 10 s (#1770): the empty page's row, saying so,
    /// with Try Again.
    static let commentsTakingLongerPageCopy = EmptyPageCopy(
        symbol: TakingLongerCopy.symbol,
        title: TakingLongerCopy.title,
        subtitle: "The comments are still on their way.",
        actionTitle: TakingLongerCopy.action
    )

    /// The failed page's headline (#794): offline and a timeout get their
    /// short forms, since the subtitle already says what to do and saying
    /// "try again" twice reads as a stutter; anything else is the view
    /// model's own words.
    static func commentsFailureTitle(_ message: String) -> String {
        switch message {
        case FailureCopy.offline: FailureCopy.offlineTitle
        case FailureCopy.timeout: FailureCopy.timeoutTitle
        default: message
        }
    }
}
