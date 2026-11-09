import DesignSystem
import Foundation

/// A group's words (#2214, #2217), each in ONE place: the thread's header,
/// the info screen and the visibility switch say a group the same way.
enum GroupCopy {
    /// "1 member", "40 members".
    static func memberCount(_ count: Int) -> String {
        let clamped = max(0, count)
        return clamped == 1 ? "1 member" : "\(clamped) members"
    }

    /// "1 follower", "2.3K followers" — compact, as a channel's subscribers.
    static func followerCount(_ count: Int) -> String {
        let clamped = max(0, count)
        return clamped == 1 ? "1 follower" : "\(CountFormatter.compactString(for: Int64(clamped))) followers"
    }

    /// Under the group's name (#2217): its members — and, for a public
    /// group, its followers apart: "40 members · 2.3K followers". A private
    /// group has no audience to count.
    static func header(memberCount: Int, followerCount: Int, visibility: ConversationVisibility) -> String {
        guard visibility == .public else { return Self.memberCount(memberCount) }
        return "\(Self.memberCount(memberCount)) · \(Self.followerCount(followerCount))"
    }

    /// The visibilities a group's owner and admins switch between (#2217).
    static let choosableVisibilities: [ConversationVisibility] = [.private, .public]

    /// A visibility's name on the info screen's switch.
    static func visibilityTitle(_ visibility: ConversationVisibility) -> String {
        visibility == .public ? "Public" : "Private"
    }

    /// What a visibility means, under the switch and in its menu.
    static func visibilityExplanation(_ visibility: ConversationVisibility) -> String {
        visibility == .public
            ? "Anyone with a link can read it and follow it, and join while it has room."
            : "Only members can read it. People join when invited."
    }

    /// The question before a switch (#2217): going public opens what is
    /// said from now on — not before — to anyone; going private closes it
    /// to its followers at once. Both are asked first.
    static func visibilityConfirmation(_ visibility: ConversationVisibility) -> (title: String, message: String, button: String) {
        visibility == .public
            ? ("Make this group public?",
               "Anyone with a link will be able to read what's said here from now on, follow the group and join it while it has room. Earlier messages stay among members.",
               "Make Public")
            : ("Make this group private?",
               "Its followers will lose it at once. Only members will be able to read it.",
               "Make Private")
    }

    /// The line a follower's open thread shows once the group turned
    /// private (#2217).
    static let privateNow = "This group is private now"
}
