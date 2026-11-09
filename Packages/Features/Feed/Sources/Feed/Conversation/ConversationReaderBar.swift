import DesignSystem
import FeedInterface
import UIKit

/// What a channel offers a viewer who doesn't post, in the composer's place
/// (#2215): a subscriber's Mute / Unmute and Leave; an outsider's Join or
/// Request to Join; a pending request's Requested.
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
    }

    var onAction: ((Action) -> Void)?

    private let primary = AppButton(aspect: .pill(.prominent), size: .form, content: .title("Join Channel"))
    private let secondary = AppButton(aspect: .pill(.quiet), size: .form, content: .title("Leave"))
    private let note = UILabel()
    private let stack = UIStackView()
    private(set) var standing: ConversationThreadReaderStanding = .subscribed
    private(set) var isMuted = false
    private var primaryAction: Action?

    override init(frame: CGRect) {
        super.init(frame: frame)
        note.font = .appFont(forTextStyle: .subheadline)
        note.textColor = .secondaryLabel
        note.textAlignment = .center
        note.numberOfLines = 0
        note.adjustsFontForContentSizeCategory = true
        primary.addAction(UIAction { [weak self] _ in
            guard let self, let action = self.primaryAction else { return }
            self.onAction?(action)
        }, for: .primaryActionTriggered)
        secondary.addAction(UIAction { [weak self] _ in self?.onAction?(.leave) }, for: .primaryActionTriggered)
        stack.addArrangedSubview(primary)
        stack.addArrangedSubview(secondary)
        stack.addArrangedSubview(note)
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
        secondary.isHidden = !spec.showsLeave
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
        let showsLeave: Bool
        let note: String?
    }

    static func spec(for standing: ConversationThreadReaderStanding, isMuted: Bool) -> Spec {
        switch standing {
        case .subscribed:
            Spec(
                primary: .init(
                    title: isMuted ? "Unmute" : "Mute", symbol: isMuted ? "bell.fill" : "bell.slash", action: .toggleMute
                ),
                primaryIsQuiet: true, showsLeave: true, note: nil
            )
        case .canJoin:
            Spec(primary: .init(title: "Join Channel", symbol: nil, action: .join), primaryIsQuiet: false, showsLeave: false, note: nil)
        case .canRequest:
            Spec(primary: .init(title: "Request to Join", symbol: nil, action: .join), primaryIsQuiet: false, showsLeave: false, note: nil)
        case .requested:
            Spec(
                primary: .init(title: "Requested", symbol: "clock", action: .cancelRequest),
                primaryIsQuiet: true, showsLeave: false, note: nil
            )
        case .unavailable:
            Spec(primary: nil, primaryIsQuiet: false, showsLeave: false, note: "You can't join this channel.")
        }
    }

    /// A write is on its way: the tapped button holds its place, loading.
    func setWorking(_ working: Bool) {
        primary.setPhase(working ? .loading : .content, animated: window != nil)
    }
}
