import ThreadKit
import UIKit

/// ⚠️ A REPLY RIDES THE KEYBOARD (#2487, the owner 2026-11-18 and 2026-11-25).
/// Popular stays where it is when the keyboard comes up (2026-11-01), and so
/// do both tabs under the comments sheet's detached composer (2026-11-04): a
/// tap in the field moves nothing. A reply is the one exception — the comment
/// being answered must stay in view — so a keyboard that rises for a reply
/// lifts the stream as it lifts the text page's Recent
/// (`CommentStream.syncKeyboardRise`, the one mechanism) — never so far that
/// comment leaves the view, and far enough for a low one to end just above
/// the field (`keepAnsweredRow`).
///
/// - **Starts** when the keyboard rises while a reply entered from this
///   stream is armed (`rowID`, the tapped comment, and the panel's
///   `replyTarget`). Layout passes before the keys come (the sheet expanding
///   for the reply, #2153) keep it armed.
/// - **Lasts** until the keyboard is down, even if the reply is cancelled
///   meanwhile (the chip's ✕): the content does not jump back while the
///   reader is typing.
/// - **Ends** with the keyboard: the inset back to rest, and the stream back
///   at rest on the keyboard's curve — Popular from the top, Recent at its
///   end, or where the reader stood as the ride began (`startOffset`).
struct ReplyKeyboardRise: Equatable {
    /// The comment the reader tapped to answer from this stream, until the
    /// keyboard has gone again.
    var rowID: String?
    /// Whether the stream rides the keyboard now.
    private(set) var isRiding = false
    /// Where the stream stood as the ride began: a reader's Recent goes back
    /// there with the keys, its rise capped or not (`keepAnsweredRow`).
    var startOffset: CGFloat?

    /// Whether the stream follows a keyboard that holds the composer `rise`
    /// above its rest, `replying` when the panel has a reply armed. True
    /// while it rides, and once more as the keyboard comes down, so the
    /// stream goes back to rest; false for a plain tap in the field.
    mutating func follows(rise: CGFloat, replying: Bool) -> Bool {
        guard rise > 0.5 else {
            defer {
                // A reply armed and not ridden yet waits for its keys.
                if isRiding || !replying { rowID = nil }
                isRiding = false
            }
            return isRiding
        }
        if !isRiding, replying, rowID != nil {
            isRiding = true
            startOffset = nil
        }
        return isRiding
    }
}

extension CommentStream {
    /// A row's Reply: the comment it answers is remembered for the
    /// keyboard's rise, then the panel arms the composer.
    func enterReplyState(for model: CommentDisplayModel) {
        replyRise.rowID = model.id
        host.enterReplyState(for: model)
    }

    /// Whether this stream's bottom inset follows the keyboard's `rise`:
    /// a reply's always (`ReplyKeyboardRise`), and every keyboard for Recent
    /// on a panel whose composer rides the keys (`streamsRideKeyboard`).
    /// The rule is asked every time, so it hears the keyboard go.
    func ridesKeyboard(_ rise: CGFloat) -> Bool {
        let ridesReply = replyRise.follows(rise: rise, replying: host.replyTarget != nil)
        return (kind == .recent && host.streamsRideKeyboard) || ridesReply
    }

    /// The offset as the keyboard moves by `delta`, the inset already set,
    /// from `offsetBefore`: the rows rise with it. Recent keeps its end when
    /// it held it, and its reader's rows otherwise; Popular, once a reply's
    /// keyboard has gone, is back at rest, from the top. While a reply
    /// rides, the comment being answered stays in view (`keepAnsweredRow`).
    func followKeyboardRise(from offsetBefore: CGFloat, by delta: CGFloat) {
        var target = offsetBefore + delta
        if replyRise.isRiding, replyRise.startOffset == nil {
            replyRise.startOffset = offsetBefore
        } else if !replyRise.isRiding, let start = replyRise.startOffset {
            replyRise.startOffset = nil
            target = start
        }
        if kind == .recent, holdsRest {
            pinToTail()
        } else if kind == .popular, !replyRise.isRiding {
            collectionView.contentOffset.y = resting.restingOffset(of: collectionView)
        } else {
            let lowest = -collectionView.adjustedContentInset.top
            collectionView.contentOffset.y = min(max(target, lowest), tailOffset)
        }
        if replyRise.isRiding { keepAnsweredRow(risingFrom: offsetBefore) }
    }

    /// ⚠️ THE COMMENT ANSWERED STAYS IN VIEW (#2487, decided 2026-11-25):
    /// risen by the whole keyboard, a comment high up went under the bar.
    /// The rows rise with the keys, but never past the point where its top
    /// sits at the room's top; a low one scrolls on until it ends just over
    /// the field, which wins for a comment taller than the room. Never below
    /// `offsetBefore`, never past what the stream can scroll to.
    private func keepAnsweredRow(risingFrom offsetBefore: CGFloat) {
        guard let answered = answeredRowFrame() else { return }
        let insets = collectionView.adjustedContentInset
        let topAtRoomTop = max(answered.minY - insets.top, offsetBefore)
        let endOverField = answered.maxY - (collectionView.bounds.height - insets.bottom)
        let target = max(min(collectionView.contentOffset.y, topAtRoomTop), endOverField)
        collectionView.contentOffset.y = min(max(target, -insets.top), tailOffset)
    }

    /// The frame of the comment being answered, in the stream's content.
    private func answeredRowFrame() -> CGRect? {
        guard let id = replyRise.rowID, let dataSource = streamDataSource,
              let indexPath = dataSource.indexPath(for: .comment(id)) else { return nil }
        return collectionView.layoutAttributesForItem(at: indexPath)?.frame
    }
}
