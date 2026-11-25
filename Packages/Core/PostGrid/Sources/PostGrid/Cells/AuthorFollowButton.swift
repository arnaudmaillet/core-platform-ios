import DesignSystem
import UIKit

/// THE FOLLOW IN A LIST ROW'S AUTHOR BAND (#2419, the owner 2026-11-13):
/// right-aligned, just left of the "…", since the face's badge became
/// information only. `(◯) Name / @handle · 2h ……… (Follow) •••`
///
/// The app's ROW ACTION (#2231): Follow repeats on every row, so it stands on
/// the tinted ground, not the prominent fill the full-screen page's single
/// Follow wears (#2409). The same morph and loading as every row action
/// (`AppButton`), at the band's pill height.
///
/// It draws an `AuthorFollowOffer`, and the offer's changes:
/// - Follow, Follow back: tinted; a tap is the host's follow (`onFollow`);
/// - Requested: quiet, and it stays. A tap offers to cancel the request
///   (`onCancelRequest`, through a menu);
/// - followed (from Follow or Follow back, seen on screen): "✓ Following"
///   for `confirmationDuration`, then the button folds away and the name
///   gets the room back;
/// - nothing (the viewer's own post, blocked, not known yet): no button. An
///   answer that lands later makes the button come in, never the name jump.
/// A row filled afresh draws its offer at once (`animated: false`).
public final class AuthorFollowButton: AppButton {
    /// How long "✓ Following" stays before the button folds (#2409's
    /// confirmation, the same here).
    public static let confirmationDuration: TimeInterval = 1

    /// The offer drawn now.
    public private(set) var offer: AuthorFollowOffer = .none
    /// Whether "✓ Following" is on show, waiting for its fold.
    public private(set) var isConfirming = false
    /// Told on a tap on Follow or Follow back: the host follows.
    public var onFollow: (() -> Void)?
    /// Told when the viewer confirms cancelling a request from the menu.
    public var onCancelRequest: (() -> Void)?
    /// Who the button follows, for VoiceOver ("Follow Ava Moreau").
    public var personName: String? { didSet { applyAccessibility() } }

    private var fold: LoadingTimer?

    public init() {
        super.init(aspect: .rowAction, size: .row, content: .title(Self.title(for: .follow)))
        // The trailing edge stays put through every morph: the "…" is there.
        morphAnchor = .trailing
        isHidden = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        addAction(UIAction { [weak self] _ in self?.tapped() }, for: .primaryActionTriggered)
    }

    /// Draws `offer`: animated when the change is seen on screen, at once
    /// otherwise (a row filled afresh, a reuse).
    public func show(_ offer: AuthorFollowOffer, animated: Bool) {
        let old = self.offer
        guard offer != old else { return }
        self.offer = offer
        let seen = animated && window != nil
        // A confirmation under way gives way to whatever comes next: a
        // private account's "Requested", an unfollow, a reuse.
        cancelFold()
        applyMenu()
        applyAccessibility()
        if offer.showsButton {
            let content = AppButton.Content.title(Self.title(for: offer))
            let selected = offer == .requested
            if isHidden {
                setContent(content, selected: selected, animated: false)
                appear(animated: seen)
            } else {
                setContent(content, selected: selected, animated: seen)
            }
            return
        }
        // Followed from the button's own invitation, on screen: say so, then
        // fold (#2419, as #2409's).
        if offer == .following, seen, !isHidden, old == .follow || old == .followBack {
            isConfirming = true
            setContent(AppButton.Content(title: "Following", symbol: "checkmark"), selected: true, animated: true)
            fold = loadClock.schedule(Self.confirmationDuration) { [weak self] in
                guard let self else { return }
                fold = nil
                isConfirming = false
                foldAway(animated: window != nil)
            }
            return
        }
        foldAway(animated: seen)
    }

    /// Folds away WHERE IT STANDS: a stand-in (its own pixels) scales out
    /// and fades in the band, while the controls' stack closes and the name
    /// takes the room back. ⚠️ Not `AppControl.disappear`: its stand-in rides
    /// the stack, and a trailing-pinned stack that shrinks slid it right,
    /// over the "…" (filmed, 2026-11-25).
    private func foldAway(animated: Bool) {
        guard animated, window != nil, !isHidden, let stack = superview,
              let band = stack.superview, let ghost = snapshotView(afterScreenUpdates: false) else {
            isHidden = true
            return
        }
        ghost.isUserInteractionEnabled = false
        ghost.frame = convert(bounds, to: band)
        band.addSubview(ghost)
        isHidden = true
        let reduced = UIAccessibility.isReduceMotionEnabled
        UIView.animate(
            withDuration: reduced ? AppearMotion.fadeDuration : AppearMotion.disappearDuration,
            delay: 0, options: [.curveEaseInOut, .allowUserInteraction]
        ) { band.layoutIfNeeded() }
        AppearMotion.disappear(ghost, reducesMotion: reduced, completion: { _ in ghost.removeFromSuperview() })
    }

    private func cancelFold() {
        fold?.cancel()
        fold = nil
        isConfirming = false
    }

    private func tapped() {
        switch offer {
        case .follow, .followBack: onFollow?()
        case .requested, .none, .following: break
        }
    }

    /// Requested: a tap opens the menu that cancels the request, the menu
    /// itself the button's action, so no frame shows the press alone.
    private func applyMenu() {
        guard offer == .requested else {
            showsMenuAsPrimaryAction = false
            menu = nil
            return
        }
        let cancel = UIAction(title: "Cancel Request", image: UIImage(systemName: "xmark"), attributes: .destructive) {
            [weak self] _ in self?.onCancelRequest?()
        }
        menu = UIMenu(children: [cancel])
        showsMenuAsPrimaryAction = true
    }

    private func applyAccessibility() {
        let name = personName.map { " " + $0 } ?? ""
        accessibilityLabel = switch offer {
        case .follow: "Follow" + name
        case .followBack: "Follow" + name + " back"
        case .requested: "Requested"
        case .following, .none: "Following"
        }
        accessibilityHint = offer == .requested ? "Offers to cancel your follow request." : nil
    }

    /// The words for an offer that draws a button.
    static func title(for offer: AuthorFollowOffer) -> String {
        switch offer {
        case .followBack: "Follow back"
        case .requested: "Requested"
        case .follow, .following, .none: "Follow"
        }
    }

    #if DEBUG
    /// The confirmation's fold, run now. Tests.
    public func debugFold() {
        guard let fold else { return }
        fold.cancel()
        self.fold = nil
        isConfirming = false
        foldAway(animated: false)
    }
    #endif
}
