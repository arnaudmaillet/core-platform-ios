import DesignSystem
import FeedInterface
import UIKit

/// What a channel offers a viewer who doesn't post, in the composer's place
/// (#2215): a subscriber's Mute / Unmute and Leave; an outsider's Join or
/// Request to Join; a pending request's Requested.
///
/// And a public group (#2217): an outsider's Join and Follow, a follower's
/// Join and Following — Join only while the group has room, "This group is
/// full" in its place once it hasn't.
///
/// It draws what it is told — the standing comes from the driver
/// (`ConversationThreadGroup.readerStanding`), the mute from the thread's
/// bell — and says what was tapped. Confirmations are the screen's.
final class ConversationReaderBar: UIView {
    /// What a tap asks for.
    enum Action: Equatable {
        case toggleMute
        case leave
        case join
        case cancelRequest
        case follow
        case unfollow
    }

    var onAction: ((Action) -> Void)?

    private let primary = AppButton(aspect: .pill(.prominent), size: .form, content: .title("Join Channel"))
    private let secondary = AppButton(aspect: .pill(.quiet), size: .form, content: .title("Leave"))
    private let note = UILabel()
    private let stack = UIStackView()
    private(set) var standing: ConversationThreadReaderStanding = .subscribed
    private(set) var isMuted = false
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
        configure(standing: .subscribed, isMuted: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The words and the actions for `standing`; `isMuted` names the
    /// subscriber's bell.
    func configure(standing: ConversationThreadReaderStanding, isMuted: Bool) {
        self.standing = standing
        self.isMuted = isMuted
        let spec = Self.spec(for: standing, isMuted: isMuted)
        primaryAction = spec.primary?.action
        if let primarySpec = spec.primary {
            primary.setContent(AppButton.Content(title: primarySpec.title, symbol: primarySpec.symbol), animated: window != nil)
        }
        primary.isHidden = spec.primary == nil
        // A subscriber's bell is quiet: the action that matters is reading.
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
        /// The subscriber's Mute is drawn quiet, not prominent.
        let primaryIsQuiet: Bool
        /// Always quiet: a channel's Leave, a group's Follow or Following.
        let secondary: Button?
        let note: String?

        init(primary: Button?, primaryIsQuiet: Bool, secondary: Button? = nil, note: String?) {
            self.primary = primary
            self.primaryIsQuiet = primaryIsQuiet
            self.secondary = secondary
            self.note = note
        }

        var showsLeave: Bool { secondary?.action == .leave }
        /// Nothing to draw: the bar hides (a group closed to the viewer).
        var isEmpty: Bool { primary == nil && secondary == nil && note == nil }
    }

    static let leave = Spec.Button(title: "Leave", symbol: nil, action: .leave)
    /// A full group's note, where its Join would be (#2217).
    static let fullNote = "This group is full"

    static func spec(for standing: ConversationThreadReaderStanding, isMuted: Bool) -> Spec {
        switch standing {
        case .subscribed:
            Spec(
                primary: .init(
                    title: isMuted ? "Unmute" : "Mute", symbol: isMuted ? "bell.fill" : "bell.slash", action: .toggleMute
                ),
                primaryIsQuiet: true, secondary: leave, note: nil
            )
        case .canJoin:
            Spec(primary: .init(title: "Join Channel", symbol: nil, action: .join), primaryIsQuiet: false, note: nil)
        case .canRequest:
            Spec(primary: .init(title: "Request to Join", symbol: nil, action: .join), primaryIsQuiet: false, note: nil)
        case .requested:
            Spec(
                primary: .init(title: "Requested", symbol: "clock", action: .cancelRequest),
                primaryIsQuiet: true, note: nil
            )
        case .unavailable:
            Spec(primary: nil, primaryIsQuiet: false, note: "You can't join this channel.")
        // A public group (#2217): Join writes, Follow reads along. Past the
        // cap there is nothing to join — the note says so, Follow stays.
        case .canJoinOrFollow(let isFull):
            Spec(
                primary: isFull ? nil : .init(title: "Join", symbol: nil, action: .join), primaryIsQuiet: false,
                secondary: .init(title: "Follow", symbol: nil, action: .follow), note: isFull ? fullNote : nil
            )
        case .following(let isFull):
            Spec(
                primary: isFull ? nil : .init(title: "Join", symbol: nil, action: .join), primaryIsQuiet: false,
                secondary: .init(title: "Following", symbol: "checkmark", action: .unfollow), note: isFull ? fullNote : nil
            )
        case .closed:
            Spec(primary: nil, primaryIsQuiet: false, note: nil)
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
