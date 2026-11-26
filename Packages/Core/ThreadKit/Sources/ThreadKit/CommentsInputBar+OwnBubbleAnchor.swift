import UIKit

/// The own bubble (the emote over an empty field, the send over a draft), for
/// a host that stands something of its own on it — a text page's way back,
/// directly above it (#2488). It rides the keyboard with the input row, so
/// whatever is pinned to it rides along.
extension CommentsInputBar {
    /// The own bubble's view: pin to its centre and its top, never to its
    /// width — a voice hold grows it into the mic (#2102).
    public var ownBubbleAnchor: UIView { voiceHoldAnchor }

    /// The own bubble's resting side: the row's control size.
    public static var ownBubbleSide: CGFloat { Metrics.controlSize }
}
