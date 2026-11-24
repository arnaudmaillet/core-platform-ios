import ThreadKit
import UIKit

/// ⚠️ A REPLY ON POPULAR RIDES THE KEYBOARD (#2487, the owner 2026-11-18).
/// Popular stays where it is when the keyboard comes up (2026-11-01): a tap in
/// the field moves nothing. A reply is the one exception — the comment being
/// answered must stay in view — so a keyboard that rises for a reply lifts
/// Popular as it lifts Recent (`CommentStream.syncKeyboardRise`, the one
/// mechanism), and lifts it far enough for that comment to end just above
/// the field.
///
/// - **Starts** when the keyboard rises while a reply entered from this
///   stream is armed (`rowID`, the tapped comment, and the panel's
///   `replyTarget`).
/// - **Lasts** until the keyboard is down, even if the reply is cancelled
///   meanwhile (the chip's ✕): the content does not jump back while the
///   reader is typing.
/// - **Ends** with the keyboard: the inset back to rest, and Popular back at
///   its resting place, from the top, on the keyboard's curve.
struct ReplyKeyboardRise: Equatable {
    /// The comment the reader tapped to answer from this stream, until the
    /// keyboard has gone again.
    var rowID: String?
    /// Whether the stream rides the keyboard now.
    private(set) var isRiding = false

    /// Whether the stream follows a keyboard that holds the composer `rise`
    /// above its rest, `replying` when the panel has a reply armed. True
    /// while it rides, and once more as the keyboard comes down, so the
    /// stream goes back to rest; false for a plain tap in the field.
    mutating func follows(rise: CGFloat, replying: Bool) -> Bool {
        guard rise > 0.5 else {
            defer {
                isRiding = false
                rowID = nil
            }
            return isRiding
        }
        if !isRiding, replying, rowID != nil { isRiding = true }
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
    /// Recent's always, Popular's for a reply only (`ReplyKeyboardRise`).
    func ridesKeyboard(_ rise: CGFloat) -> Bool {
        kind == .recent || replyRise.follows(rise: rise, replying: host.replyTarget != nil)
    }

    /// Popular's offset as a reply's keyboard moves, its inset already set:
    /// `risen`, where the rows stand having risen with the keyboard as
    /// Recent's do, or further, just far enough for the comment being
    /// answered to end over the field — never past what the stream can
    /// scroll to. A comment already in view moves no further than the rise.
    /// Once the keyboard has gone: back at rest, from the top.
    func followReplyRise(to risen: CGFloat) {
        guard replyRise.isRiding else {
            collectionView.contentOffset.y = resting.restingOffset(of: collectionView)
            return
        }
        let insets = collectionView.adjustedContentInset
        let lowest = -insets.top
        let highest = max(lowest, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
        var target = risen
        if let answered = answeredRowFrame() {
            target = max(target, answered.maxY - (collectionView.bounds.height - insets.bottom))
        }
        collectionView.contentOffset.y = min(max(target, lowest), highest)
    }

    /// The frame of the comment being answered, in the stream's content.
    private func answeredRowFrame() -> CGRect? {
        guard let id = replyRise.rowID, let dataSource = streamDataSource,
              let indexPath = dataSource.indexPath(for: .comment(id)) else { return nil }
        return collectionView.layoutAttributesForItem(at: indexPath)?.frame
    }
}
