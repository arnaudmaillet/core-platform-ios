import CoreModels
import Foundation

/// A channel's showcase as Chat offers it (#2216, part 3): who may "Share as
/// a Post", and the card the Text Post screen opens with — in one place, for
/// the creation step and the info screen alike.
///
/// The composer is Upload's over Feed's screen, which Chat can't reach: the
/// screens emit `AppRoute.composeShowcase` with the card, and the app opens
/// it.
enum ChannelShowcase {
    /// Whether the viewer may share the channel as a post: its owner or an
    /// admin (`runsChannel`), of a channel the card can show — public or on
    /// request. A private one can't be probed by those who'd see the post
    /// (#2216 § 4: "A private conversation can't be shown"), so it has no
    /// "Share as a Post".
    static func canShare(viewerState: ConversationViewerState, visibility: ConversationVisibility) -> Bool {
        viewerState.runsChannel && visibility != .private
    }

    /// The card the composer shows and the create request carries: the
    /// channel as its runner's screen knows it, the viewer in it. The server
    /// hydrates it again for every reader (#995); nil for a private channel.
    static func embed(
        _ id: ConversationID, name: String, photoURL: URL?, description: String, subscriberCount: Int,
        visibility: ConversationVisibility
    ) -> PostEmbed? {
        let shown: ChannelEmbed.Visibility
        switch visibility {
        case .public: shown = .public
        case .listedOnRequest: shown = .onRequest
        case .private: return nil
        }
        return .channel(ChannelEmbed(
            conversationID: id, name: name, photoURL: photoURL, description: description,
            subscriberCount: subscriberCount, visibility: shown, viewerState: .member
        ))
    }

    /// The row and the button's words.
    static let shareTitle = "Share as a Post"
    static let shareSymbol = "square.and.pencil"
}
