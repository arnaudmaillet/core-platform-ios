import UIKit

/// WHAT A TAP AND A HOLD ON A PERSON DO, in one place (#2145, the owner
/// 2026-11-05). Each screen used to wire its own: a conversation's pill had
/// no hold while a post's pushed the profile (#2144).
///
/// **A person shown beside content** (a post's author pill, the Shots author
/// row, a conversation's correspondent pill):
/// - a tap opens the profile CARD, a look without leaving the content;
/// - a hold (0.4 s) opens the PROFILE, pushed, with `held` as it is
///   recognised; a recognised hold cancels the tap — the card never opens
///   as well;
/// - VoiceOver: the container's activation is the tap, and a custom action,
///   "Open profile", stands for the hold.
///
/// **No person, no action:** while `hasPerson` answers false (a group, an id
/// not known yet), a tap and a hold do nothing and play no haptic; they work
/// again as soon as it answers true — it is read when the gesture fires.
///
/// The host keeps the routes (`openCard`, `openProfile`): MediaCore knows no
/// routes, the screen's view model does (`.profileCard`, `.profile`).
@MainActor
public final class PersonOpening: NSObject {
    /// How long a hold takes to open the profile.
    public static let holdDuration: TimeInterval = 0.4
    /// VoiceOver's stand-in for the hold.
    public static let openProfileActionName = "Open profile"

    /// Whether there is a person to open now; read as a gesture fires.
    public var hasPerson: () -> Bool = { true }
    /// A tap: the profile card.
    public var openCard: (() -> Void)?
    /// A hold: the profile, pushed. Nil, the container takes no hold.
    public var openProfile: (() -> Void)? {
        didSet {
            hold.isEnabled = openProfile != nil
            refreshAccessibility()
        }
    }

    private weak var view: UIView?
    private let tap = UITapGestureRecognizer()
    private let hold = UILongPressGestureRecognizer()

    /// Attaches the tap and the hold to `view`, the person's container.
    public init(on view: UIView) {
        self.view = view
        super.init()
        tap.addTarget(self, action: #selector(tapped))
        hold.addTarget(self, action: #selector(held(_:)))
        hold.minimumPressDuration = Self.holdDuration
        hold.isEnabled = false
        // A hold, once recognised, is not also a tap.
        tap.require(toFail: hold)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(hold)
    }

    @objc private func tapped() { tapRecognised() }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        holdRecognised()
    }

    /// The tap's answer: the card, when there is a person.
    func tapRecognised() {
        guard hasPerson(), let openCard else { return }
        openCard()
    }

    /// The hold's answer: `held`, then the profile — nothing at all without
    /// a person, not even the haptic.
    func holdRecognised() {
        guard hasPerson(), let openProfile else { return }
        PersonHold.recognised(openProfile)
    }

    private func refreshAccessibility() {
        guard let view else { return }
        view.accessibilityCustomActions = openProfile == nil ? nil : [
            UIAccessibilityCustomAction(name: Self.openProfileActionName) { [weak self] _ in
                guard let self, hasPerson(), let openProfile else { return false }
                openProfile()
                return true
            },
        ]
    }

    #if DEBUG
    /// Whether the container takes a hold now. Tests.
    public var debugTakesHold: Bool { hold.isEnabled }
    /// A tap, as a finger's would land. Tests.
    public func debugTap() { tapRecognised() }
    /// A hold, recognised. Tests.
    public func debugHold() { holdRecognised() }
    #endif
}
