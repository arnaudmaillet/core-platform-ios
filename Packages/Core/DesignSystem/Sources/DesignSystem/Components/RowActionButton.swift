import UIKit

/// The decision on a person row — Follow, Following, Requested, Follow Back,
/// Accept, the ✕ beside them (#885): UIKit's own button, styled by a system
/// `UIButton.Configuration`, with ONE addition — a change of content
/// cross-fades instead of cutting.
///
/// Everything else is UIKit's: the `.filled()` / `.gray()` capsule, the
/// highlight the configuration resolves while a finger is down, accessibility,
/// actions.
///
/// ⚠️ **NO PRESS IS ADDED HERE, AND NONE MAY BE.** The press is the
/// configuration's own highlight — nothing scales, nothing is attached to
/// touch-down (`PressFeedback` is not used). It replaced `MorphingButton` on
/// these rows, whose blur veil, spring resize and shared press the owner asked
/// to drop for the system button.
///
/// ⚠️ **WHY A SUBCLASS AT ALL.** Measured (and pinned by
/// `aPlainSystemButtonDoesNotAnimateATitleChange`): assigning a new
/// `configuration` (directly or through `configurationUpdateHandler` /
/// `setNeedsUpdateConfiguration`) re-renders the title at once — no animation
/// is added to any layer. Only symbols can transition by themselves
/// (`symbolContentTransition`), and these buttons carry words. So
/// `setConfiguration(_:animated:)` wraps the swap in a cross-dissolve, and lets
/// the capsule's new width settle in the same beat.
open class RowActionButton: UIButton {
    /// How long a change of content takes.
    public static let transitionDuration: TimeInterval = 0.25

    /// A row action's look: a filled capsule while it invites (Follow,
    /// Follow Back, Accept), grey once it states a fact (Following,
    /// Requested).
    public enum Prominence: Sendable {
        case prominent
        case secondary
    }

    /// Whether a cross-fade is on screen now. Public for tests.
    public private(set) var isTransitioning = false
    /// Bumped per change, so a superseded fade's completion can't clear the
    /// flag of the one that replaced it.
    private var transitionGeneration = 0
    /// The configuration last asked for, through `setConfiguration` or the
    /// initializer.
    ///
    /// ⚠️ NOT `configuration`: the getter answers the configuration UIKit
    /// resolved for the button, which does not compare equal to the one that
    /// was given (measured, on screen and off) — comparing against it faded
    /// every re-apply of the same state. Public for tests.
    public private(set) var requestedConfiguration: UIButton.Configuration?

    override public init(frame: CGRect) {
        super.init(frame: frame)
    }

    public convenience init(configuration: UIButton.Configuration) {
        self.init(frame: .zero)
        apply(configuration)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The capsule every row action wears: system style, small, the app's
    /// subheadline face.
    public static func configuration(title: String, prominence: Prominence) -> UIButton.Configuration {
        var configuration: UIButton.Configuration = switch prominence {
        case .prominent: .filled()
        case .secondary: .gray()
        }
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.appFont(forTextStyle: .subheadline)
        ]))
        return configuration
    }

    /// Moves to `configuration`: cross-faded, the capsule easing to its new
    /// width, when `animated` and on screen; at once otherwise, or when
    /// nothing changes. Set the configuration through here (or the
    /// initializer), not through `configuration`, so a re-apply of the same
    /// state is known for what it is.
    public func setConfiguration(_ configuration: UIButton.Configuration, animated: Bool) {
        let animates = animated && window != nil
        // A fade still running (a reused row's last person) ends at an
        // immediate change, even to the same content: it lands whole, at its
        // own width.
        if !animates, isTransitioning {
            transitionGeneration += 1
            isTransitioning = false
            layer.removeAllAnimations()
        }
        guard requestedConfiguration != configuration else { return }
        guard animates else {
            apply(configuration)
            return
        }
        transitionGeneration += 1
        let generation = transitionGeneration
        isTransitioning = true
        UIView.transition(
            with: self, duration: Self.transitionDuration,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
        ) {
            self.apply(configuration)
            // Resolved INSIDE the transition: a configuration renders at the
            // button's next update pass, which would otherwise land after the
            // fade's "after" picture was taken.
            self.layoutIfNeeded()
        } completion: { _ in
            guard generation == self.transitionGeneration else { return }
            self.isTransitioning = false
        }
        // A fade is fine under Reduce Motion; a growing capsule is motion.
        guard !MotionPreference.reducesMotion else {
            superview?.layoutIfNeeded()
            return
        }
        UIView.animate(
            withDuration: Self.transitionDuration, delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
        ) {
            // Walks up to the outermost ancestor that needs layout, so a
            // button in a stack moves its neighbours in the same beat.
            (self.superview ?? self).layoutIfNeeded()
        }
    }

    /// Sets the configuration and makes its size count now: without the
    /// invalidation the intrinsic size still says the old title's until the
    /// next update pass.
    private func apply(_ configuration: UIButton.Configuration) {
        requestedConfiguration = configuration
        self.configuration = configuration
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
    }
}
