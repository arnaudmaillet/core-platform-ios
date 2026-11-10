import DesignSystem
import Foundation

/// A channel's words (#2215), each in ONE place: the tab, the thread's
/// header, the info screen and the creation step all say a channel the
/// same way.
enum ChannelCopy {
    /// "1 subscriber", "820 subscribers", "12.4K subscribers".
    static func subscriberCount(_ count: Int) -> String {
        let clamped = max(0, count)
        return clamped == 1 ? "1 subscriber" : "\(CountFormatter.compactString(for: Int64(clamped))) subscribers"
    }

    /// The pending requests row at the top of the Channels tab, saying
    /// WHICH channel they are for (the owner, 2026-11-10: "3 requests to
    /// join" left them asking "to join what?"): "3 requests to join Studio
    /// drops" for one channel, "5 requests to join 2 channels" for several.
    /// `channels` are the names of the channels with a request waiting.
    static func joinRequests(_ count: Int, channels: [String]) -> String {
        let requests = count == 1 ? "1 request to join" : "\(count) requests to join"
        switch channels.count {
        case 0: return requests
        case 1: return "\(requests) \(channels[0])"
        default: return "\(requests) \(channels.count) channels"
        }
    }

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

    /// The empty tab: what a channel is, and the way to make one.
    static let emptyTitle = "No channels yet"
    static let emptyMessage = "A channel is where you post to everyone who follows it. They read; only you and your admins post."
    static let createTitle = "Create a Channel"
}
