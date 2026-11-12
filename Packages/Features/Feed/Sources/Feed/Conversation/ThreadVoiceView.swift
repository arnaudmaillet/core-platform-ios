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
    /// The thread's voice: the neutral panel at full size (#2241), from the
    /// text column, its width saying its length (#2329): the narrowest up to
    /// 2 s, the full width at 30 s — the full width being the row's, held to
    /// `conversationMaxWidth` so a landscape or iPad column never stretches
    /// it. The conversation draws no bubble round a voice message: its panel
    /// is the bubble, and wears the media message's corner
    /// (`ThreadMediaView.cornerRadius`, the media tiles' token).
    static func thread() -> VoiceView {
        VoiceView(
            size: .full, leadingInset: CommentRowView.avatarSize + CommentRowView.avatarGap,
            maxPanelWidth: VoiceView.conversationMaxWidth
        )
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
