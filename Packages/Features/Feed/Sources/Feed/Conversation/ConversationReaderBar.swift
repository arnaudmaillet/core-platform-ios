import DesignSystem
import FeedInterface
import UIKit

/// What a viewer who doesn't post is offered IN, in the composer's place:
/// a channel's Join or Request to Join, a pending request's Requested
/// (#2215); a public group's Join and Follow (#2217) — Join only while the
/// group has room, "This group is full" in its place once it hasn't.
///
/// ⚠️ ONLY WHAT TAKES THE VIEWER IN (#2236, the owner 2026-11-10). What
/// takes them out — a channel's Leave, a group's Unfollow — lives in the
/// footer's ⋯ menu (and the info screen), confirmed: a red button under the
/// thumb on every read draws the eye and invites a slip, and the HIG puts a
/// destructive action in a menu or a sheet. The mute it once offered is the
/// top bar's bell, which already had it, with its durations. So a
/// channel's subscriber gets no bar at all: the thread takes the height
/// back, and the footer is the pill and the ⋯, as on a post.
///
/// It draws what it is told — the standing comes from the driver
/// (`ConversationThreadGroup.readerStanding`) — and says what was tapped.
/// Confirmations are the screen's.
final class ConversationReaderBar: UIView {
    /// What a tap asks for — ways in only (#2236): no Mute, no Leave, no
    /// Unfollow.
    enum Action: Equatable, CaseIterable {
        case join
        case cancelRequest
        case follow
    }

    var onAction: ((Action) -> Void)?

    private let primary = AppButton(aspect: .pill(.prominent), size: .form, content: .title("Join Channel"))
    private let secondary = AppButton(aspect: .pill(.quiet), size: .form, content: .title("Follow"))
    private let note = UILabel()
    private let stack = UIStackView()
    private(set) var standing: ConversationThreadReaderStanding = .closed
    private var primaryAction: Action?
    private var secondaryAction: Action?
    /// The button last tapped: the one that shows the write on its way.
    private weak var tapped: AppButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        note.font = .appFont(forTextStyle: .subheadline)
        note.textColor = .secondaryLabel
        note.textAlignment = .center
        note.numberOfLines = 0
        note.adjustsFontForContentSizeCategory = true
        primary.addAction(UIAction { [weak self] _ in
            guard let self, let action = self.primaryAction else { return }
            self.tapped = self.primary
            self.onAction?(action)
        }, for: .primaryActionTriggered)
        secondary.addAction(UIAction { [weak self] _ in
            guard let self, let action = self.secondaryAction else { return }
            self.tapped = self.secondary
            self.onAction?(action)
        }, for: .primaryActionTriggered)
        // The note leads: "This group is full" beside Follow reads as why
        // Join isn't there.
        stack.addArrangedSubview(note)
        stack.addArrangedSubview(primary)
        stack.addArrangedSubview(secondary)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = Spacing.md
        stack.pin(to: self)
        configure(standing: .closed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The words and the actions for `standing`.
    func configure(standing: ConversationThreadReaderStanding) {
        self.standing = standing
        let spec = Self.spec(for: standing)
        primaryAction = spec.primary?.action
        if let primarySpec = spec.primary {
            primary.setContent(AppButton.Content(title: primarySpec.title, symbol: primarySpec.symbol), animated: window != nil)
        }
        primary.isHidden = spec.primary == nil
        // A pending request is quiet: there is nothing more to do but wait.
        primary.setSelected(spec.primaryIsQuiet, animated: false)
        secondaryAction = spec.secondary?.action
        if let secondarySpec = spec.secondary {
            secondary.setContent(AppButton.Content(title: secondarySpec.title, symbol: secondarySpec.symbol), animated: window != nil)
        }
        secondary.isHidden = spec.secondary == nil
        note.text = spec.note
        note.isHidden = spec.note == nil
    }

    /// What one standing offers — pure, for tests.
    struct Spec: Equatable {
        struct Button: Equatable {
            let title: String
            let symbol: String?
            let action: Action
        }

        let primary: Button?
        /// A pending request's Requested is drawn quiet, not prominent.
        let primaryIsQuiet: Bool
        /// Always quiet: a public group's Follow.
        let secondary: Button?
        let note: String?

        init(primary: Button?, primaryIsQuiet: Bool = false, secondary: Button? = nil, note: String? = nil) {
            self.primary = primary
            self.primaryIsQuiet = primaryIsQuiet
            self.secondary = secondary
            self.note = note
        }

        /// Nothing to draw: no bar, and the thread takes its height back
        /// (a subscriber, #2236; a group closed to the viewer, #2217).
        var isEmpty: Bool { primary == nil && secondary == nil && note == nil }

        static let empty = Spec(primary: nil)
    }

    /// A full group's note, where its Join would be (#2217).
    static let fullNote = "This group is full"

    static func spec(for standing: ConversationThreadReaderStanding) -> Spec {
        switch standing {
        // In already (#2236): nothing takes them further in. Leave is the
        // ⋯ menu's, the mute the bell's.
        case .subscribed:
            .empty
        case .canJoin:
            Spec(primary: .init(title: "Join Channel", symbol: nil, action: .join))
        case .canRequest:
            Spec(primary: .init(title: "Request to Join", symbol: nil, action: .join))
        // Requested stays a way to withdraw (a tap asks first), the ⋯ menu's
        // Cancel Request its twin: the bar is where the request was made.
        case .requested:
            Spec(primary: .init(title: "Requested", symbol: "clock", action: .cancelRequest), primaryIsQuiet: true)
        case .unavailable:
            Spec(primary: nil, note: "You can't join this channel.")
        // A public group (#2217): Join writes, Follow reads along. Past the
        // cap there is nothing to join — the note says so, Follow stays.
        case .canJoinOrFollow(let isFull):
            Spec(
                primary: isFull ? nil : .init(title: "Join", symbol: nil, action: .join),
                secondary: .init(title: "Follow", symbol: nil, action: .follow), note: isFull ? fullNote : nil
            )
        // A follower is offered the one way further in, Join (#2236); their
        // Unfollow is the ⋯ menu's. A full group says why there is none.
        case .following(let isFull):
            Spec(primary: isFull ? nil : .init(title: "Join", symbol: nil, action: .join), note: isFull ? fullNote : nil)
        case .closed:
            .empty
        }
    }

    /// A write is on its way: the tapped button holds its place, loading.
    func setWorking(_ working: Bool) {
        guard working else {
            primary.setPhase(.content, animated: window != nil)
            secondary.setPhase(.content, animated: window != nil)
            return
        }
        (tapped ?? primary).setPhase(.loading, animated: window != nil)
    }
}

/// The way out the footer's ⋯ menu offers a reader (#2236): the other half
/// of the reader bar's rule — the bar takes the viewer in, the menu takes
/// them out, each behind a confirmation.
enum ConversationReaderExit: Equatable {
    /// A channel's subscriber: Leave Channel, in red.
    case leaveChannel
    /// A pending request: Cancel Request — the bar's Requested does the same.
    case cancelRequest
    /// A public group's follower: Unfollow, in red.
    case unfollow

    /// The way out for `standing`; nil for a viewer who posts (no standing:
    /// an owner hands a channel over from its info screen first, a group's
    /// member leaves from its info screen) and for one with nothing to
    /// leave.
    init?(standing: ConversationThreadReaderStanding?) {
        switch standing {
        case .subscribed: self = .leaveChannel
        case .requested: self = .cancelRequest
        case .following: self = .unfollow
        case .canJoin, .canRequest, .unavailable, .canJoinOrFollow, .closed, nil: return nil
        }
    }

    var title: String {
        switch self {
        case .leaveChannel: "Leave Channel"
        case .cancelRequest: "Cancel Request"
        case .unfollow: "Unfollow"
        }
    }

    var symbol: String {
        switch self {
        case .leaveChannel: "rectangle.portrait.and.arrow.right"
        case .cancelRequest: "xmark.circle"
        case .unfollow: "minus.circle"
        }
    }

    /// Leaving and unfollowing take something away; withdrawing a request
    /// only takes back an ask.
    var isDestructive: Bool { self != .cancelRequest }
}
