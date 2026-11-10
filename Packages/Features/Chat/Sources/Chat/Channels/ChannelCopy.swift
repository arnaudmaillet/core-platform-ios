import DesignSystem
import Foundation

/// A channel's words (#2215), each in ONE place: its row in Chats, the
/// Join requests section, the thread's header, the info screen and the
/// creation step all say a channel the same way.
enum ChannelCopy {
    /// "1 subscriber", "820 subscribers", "12.4K subscribers".
    static func subscriberCount(_ count: Int) -> String {
        let clamped = max(0, count)
        return clamped == 1 ? "1 subscriber" : "\(CountFormatter.compactString(for: Int64(clamped))) subscribers"
    }

    /// A row of Requests' Join requests section (#2230): the channel, and
    /// how many wait — "Night walks · 3 requests". It names the channel
    /// (the owner, 2026-11-10, on the Channels tab's "3 requests to join":
    /// to join what?).
    static func joinRequestsRow(channel: String, count: Int) -> String {
        let requests = count == 1 ? "1 request" : "\(count) requests"
        return channel.isEmpty ? requests : "\(channel) · \(requests)"
    }

    /// The line under it.
    static let joinRequestsRowMessage = "Approve or decline who asked to join"

    /// A visibility's name, on the info screen and the creation step.
    static func visibilityTitle(_ visibility: ConversationVisibility) -> String {
        switch visibility {
        case .public: "Public"
        case .listedOnRequest: "On request"
        case .private: "Private"
        }
    }

    /// What a visibility means for someone who finds the channel.
    static func visibilityExplanation(_ visibility: ConversationVisibility) -> String {
        switch visibility {
        case .public: "Anyone can join and read it."
        case .listedOnRequest: "Anyone can find it; joining waits for you or an admin to approve."
        case .private: "Only people you invite can join."
        }
    }

    /// The visibilities a channel's owner picks from (#2211's choice):
    /// public, or listed on request.
    static let choosableVisibilities: [ConversationVisibility] = [.public, .listedOnRequest]

    /// Why the viewer can't leave, if they can't: the owner hands the
    /// channel over first (chat.v1 refuses an owner's Leave).
    static func leaveBlockedReason(for role: ConversationRole?) -> String? {
        role == .owner
            ? "You own this channel. Before you leave, make one of its admins the owner from their menu in Admins."
            : nil
    }

    /// What a channel is, in two lines: the creation sheet's header
    /// (#2230), the words the Channels tab said when it was empty (#2215).
    static let whatItIs = "A channel is where you post to everyone who follows it. They read; only you and your admins post."

    /// The "+" menu's entry and the inbox search's row (#2230).
    static let newChannelTitle = "New Channel"
    /// The search row's line under it.
    static let newChannelMessage = "Post to everyone who follows it"

    /// Leaving, confirmed (#2215; from a row, #2230).
    static func leaveTitle(_ name: String) -> String {
        name.isEmpty ? "Leave this channel?" : "Leave \(name)?"
    }
    static let leaveMessage = "You won't see its posts any more."
    /// What the owner who asked to leave is offered: the info screen,
    /// where they hand the channel over (#2230).
    static let openInfoTitle = "Channel Info"
}
