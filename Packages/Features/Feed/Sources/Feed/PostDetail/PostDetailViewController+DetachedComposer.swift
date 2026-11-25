import UIKit

/// The comments sheet's detached composer, seen from the panel (#2487).
extension PostDetailViewController {
    /// The detached composer stands `rise` points over the panel's own
    /// composer, in the panel's points: the keys it edits over have come,
    /// moved or gone. Called from the composer's layout, which the keyboard
    /// runs inside its own animation, so the streams follow on its curve.
    ///
    /// ⚠️ A REPLY ALONE RIDES IT (the owner, 2026-11-25): the stream the
    /// reply came from rises over the composer and the keys, the comment
    /// being answered just above the field, on either tab. A plain tap in
    /// the field moves nothing, as under the detached composer since
    /// 2026-11-04 (`streamsRideKeyboard` is off in the sheet). The rise is
    /// kept for the panel's own layout passes (`viewDidLayoutSubviews`).
    func followDetachedComposer(rise: CGFloat) {
        detachedComposerRise = max(0, rise)
        streams.forEach { $0.syncKeyboardRise(detachedComposerRise) }
    }
}
