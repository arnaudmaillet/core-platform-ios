import UIKit

/// A conversation's bell menu (#729), the ONE builder (#2237): the thread's
/// bell and a group's or a channel's info screen wear the same menu — Unmute
/// once muted, then Mute Notifications with how long — so a duration added
/// here shows on every bell.
///
/// A tap on the bell toggles the mute it shows; this menu is its long press.
/// The bell's glyph says the state (`symbol(muted:)`).
@MainActor
public enum MuteMenu {
    /// How long a mute lasts, and what its toast says once the server agreed.
    public struct Duration: Equatable, Sendable {
        public let title: String
        public let toast: String
        /// Nil: until the viewer turns it back on.
        public let seconds: TimeInterval?

        public init(title: String, toast: String, seconds: TimeInterval?) {
            self.title = title
            self.toast = toast
            self.seconds = seconds
        }

        /// When a mute picked `now` ends; nil for one with no end.
        public func end(from now: Date = Date()) -> Date? {
            seconds.map { now.addingTimeInterval($0) }
        }
    }

    /// The durations, shortest first (#729).
    public static let durations: [Duration] = [
        Duration(title: "For 1 Hour", toast: "Muted for 1 hour", seconds: 3_600),
        Duration(title: "For 8 Hours", toast: "Muted for 8 hours", seconds: 8 * 3_600),
        Duration(title: "For 1 Day", toast: "Muted for 1 day", seconds: 86_400),
        Duration(title: "For 1 Week", toast: "Muted for 1 week", seconds: 7 * 86_400),
        Duration(title: "Until I Turn It Back On", toast: "Notifications muted", seconds: nil),
    ]

    /// The bell's glyph for the mute it shows.
    public static func symbol(muted: Bool) -> String { muted ? "bell.slash" : "bell" }

    /// What VoiceOver says the bell holds.
    public static func accessibilityValue(muted: Bool) -> String { muted ? "Muted" : "On" }

    /// The menu for the mute now: Mute Notifications and its durations,
    /// inline; once muted, Unmute first, then Mute Again folded.
    public static func make(
        muted: Bool, onMute: @escaping (Duration) -> Void, onUnmute: @escaping () -> Void
    ) -> UIMenu {
        let choices: [UIMenuElement] = durations.map { duration in
            UIAction(title: duration.title) { _ in onMute(duration) }
        }
        let mute = UIMenu(
            title: muted ? "Mute Again" : "Mute Notifications", image: UIImage(systemName: "bell.slash"),
            options: muted ? [] : .displayInline, children: choices
        )
        guard muted else { return UIMenu(children: [mute]) }
        let unmute = UIAction(title: "Unmute", image: UIImage(systemName: "bell")) { _ in onUnmute() }
        return UIMenu(children: [unmute, mute])
    }
}
