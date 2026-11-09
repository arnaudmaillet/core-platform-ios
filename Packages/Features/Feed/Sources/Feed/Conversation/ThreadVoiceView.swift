import DesignSystem
import FeedInterface
import UIKit
import VoiceKitUI

/// The conversation's voice message bubble (#2104) is the app's voice
/// component, `VoiceView`, moved to VoiceKitUI so every surface that draws a
/// voice post reaches it (#2205). The thread keeps its name for it, and its
/// look: full size, indented to the text column.
typealias ThreadVoiceView = VoiceView

extension VoiceView {
    /// The thread's bubble: full size, at the text column.
    static func thread() -> VoiceView {
        VoiceView(size: .full, leadingInset: CommentRowView.avatarSize + CommentRowView.avatarGap)
    }
}

extension VoiceView.State.Delivery {
    /// A message's delivery, as the bubble shows it.
    init(_ delivery: ConversationThreadDelivery) {
        switch delivery {
        case .sent: self = .sent
        case .sending: self = .sending
        case .failed: self = .failed
        }
    }
}
