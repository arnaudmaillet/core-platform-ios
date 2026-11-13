import ThreadKit
import UIKit
import VoiceKitUI

/// The conversation's list. Its controls answer the finger at once: a
/// voice message's play button turned only when the finger lifted, the
/// scroll view holding its touch-down back (the owner's device check,
/// 2026-11-06).
///
/// - **Touches reach the rows without the scroll view's wait**
///   (`delaysContentTouches` off), so a press shows while the finger is down.
/// - **A scroll may still start on a control** — `UIScrollView` refuses it by
///   default once touches are not delayed — except on a voice message,
///   whose drags are its own (`ThreadVoiceView`).
final class ConversationCollectionView: UICollectionView {
    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        delaysContentTouches = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        if sequence(first: view, next: { $0.superview }).contains(where: { $0 is ThreadVoiceView }) {
            return false
        }
        return view is UIControl ? true : super.touchesShouldCancel(in: view)
    }
}
