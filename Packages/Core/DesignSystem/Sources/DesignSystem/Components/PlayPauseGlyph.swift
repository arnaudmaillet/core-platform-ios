import UIKit

/// PLAY ⇄ PAUSE, ONE SWAP (#2276): every place whose glyph turns from ▶︎ to
/// ❚❚ and back (`AppSymbol.play` / `.pause`) swaps it here, so the app has
/// one motion for it, not one per screen.
///
/// ```
/// replace        the system's Replace, .offUp at twice the speed — the old
///                glyph goes at once, the new one is up in a tenth of a second
/// scaleAndFade   the old one shrinks to 0.4 and fades on a copy while the
///                new one springs up from 0.4 as it fades in (view animations)
/// crossFade      Reduce Motion, whatever the site
/// cut            not animated (off screen, a row filled afresh)
/// ```
///
/// ⚠️ WHY TWO MOTIONS (the owner, 2026-10-16): inside Liquid Glass the
/// system's Replace is drawn in the glass's own pass — on a device it
/// stuttered ("as if at 30 fps"), on the simulator it was a plain cut, at any
/// speed. View animations the glass composites like any other, so a glyph in
/// glass scales and fades instead.
///
/// ⚠️ ONE SWITCH (`swap(for:)`): whether Replace holds up on the owner's
/// custom symbols is a device check (#2276). Each site's motion is decided
/// there and nowhere else; if Replace stutters or cuts on a device, a site
/// moves to `.scaleAndFade` by one line.
@MainActor
public enum PlayPauseGlyph {
    /// The places a play glyph turns into a pause.
    public enum Site: CaseIterable, Sendable {
        /// The voice message's play button (`VoiceView`, an `AppIconButton`
        /// glyph, no ground since #2274).
        case voicePanel
        /// The sound sheet's record: the glyph in its glass button.
        case soundSheet
        /// The voice composer's time chip (● / ▶︎ / ❚❚).
        case voiceComposerChip
        /// The voice composer's take button (❚❚ / 🎙).
        case voiceComposerTake
        /// The media editor's timeline button.
        case mediaTimeline
        /// The media editor's flash, in its glass capsule.
        case mediaFlash
    }

    /// How a site swaps when it animates.
    public enum Swap: Equatable, Sendable {
        case replace
        case scaleAndFade
    }

    /// What a swap ran — a test reads the decision.
    public enum Motion: Equatable, Sendable {
        case cut, replace, scaleAndFade, crossFade
    }

    /// ⚠️ THE ONE SWITCH: each site's motion. Outside glass the system's
    /// Replace; inside Liquid Glass, and wherever Replace leaves the glyph's
    /// place empty, the scale and fade.
    ///
    /// ⚠️ THE VOICE PANEL OVERLAPS (#2329, the owner's recording): its
    /// Replace sent the old glyph off before the new one came, and frames at
    /// 8 fps showed no glyph at all. The scale and fade keeps the old one on
    /// a copy while the new one grows in: a glyph on every frame.
    public static func swap(for site: Site) -> Swap {
        switch site {
        case .voicePanel, .soundSheet, .mediaFlash:
            .scaleAndFade
        case .voiceComposerChip, .voiceComposerTake, .mediaTimeline:
            .replace
        }
    }

    /// The motion a swap at `site` runs.
    public static func motion(for site: Site, animated: Bool, reducesMotion: Bool) -> Motion {
        guard animated else { return .cut }
        if reducesMotion { return .crossFade }
        return swap(for: site) == .replace ? .replace : .scaleAndFade
    }

    /// The system's Replace, as the voice's play button first took it:
    /// off-up at twice the speed — the default down-up shrank the old glyph
    /// first, a third of a second behind the tap. A button's configuration
    /// takes it as this; an image view as `replace(_:with:)` plays it.
    public static let replaceTransition = UISymbolContentTransition(.replace.offUp, options: .speed(2))

    /// The same Replace on an image view.
    static func replace(_ imageView: UIImageView, with image: UIImage) {
        imageView.setSymbolImage(image, contentTransition: .replace.offUp, options: .speed(2))
    }

    /// How small a glyph is when it leaves, and when the next one starts.
    public static let swapScale: CGFloat = 0.4
    static let leaveDuration: TimeInterval = 0.16
    static let arriveDuration: TimeInterval = 0.42
    static let arriveDelay: TimeInterval = 0.06
    static let arriveDamping: CGFloat = 0.55
    /// Reduce Motion's cross-fade: the old glyph dissolves into the new one
    /// in place, nothing scales or moves.
    public static let crossFadeDuration: TimeInterval = 0.2
    /// The cross-fade's key on the swapped view's layer.
    /// ⚠️ A `CATransition` is always stored under `kCATransition`, whatever
    /// key it is added with — so that is the key to read it back by.
    public static let crossFadeKey = kCATransition

    /// The view's content, just changed, dissolves in from what it showed.
    private static func crossFade(_ view: UIView) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = crossFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer.add(fade, forKey: crossFadeKey)
    }

    // MARK: - An image view

    /// Shows `image` in `imageView` by `site`'s motion. A swap overtaking
    /// one in flight starts from where that one had got to, and leaves one
    /// glyph when it ends.
    @discardableResult
    public static func swap(
        _ imageView: UIImageView, to image: UIImage?, site: Site, animated: Bool,
        reducesMotion: Bool = MotionPreference.reducesMotion
    ) -> Motion {
        let chosen = motion(for: site, animated: animated && imageView.image != nil, reducesMotion: reducesMotion)
        switch chosen {
        case .cut:
            settleGlyph(imageView)
            imageView.image = image
        case .replace:
            settleGlyph(imageView)
            if let image, image.isSymbolImage {
                replace(imageView, with: image)
            } else {
                imageView.image = image
            }
        case .crossFade:
            settleGlyph(imageView)
            imageView.image = image
            crossFade(imageView)
        case .scaleAndFade:
            scaleAndFade(imageView, to: image)
        }
        return chosen
    }

    /// The image view's own glyph shrinks away on a copy, and the view
    /// springs the new one up from small.
    private static func scaleAndFade(_ imageView: UIImageView, to image: UIImage?) {
        guard let host = imageView.superview else {
            settleGlyph(imageView)
            imageView.image = image
            return
        }
        // From where the glyph is now: mid-swap, the arriving one's alpha and
        // scale as drawn.
        let shown = imageView.layer.presentation()
        let fromAlpha = shown.map { CGFloat($0.opacity) } ?? imageView.alpha
        let fromTransform = shown.map { CATransform3DGetAffineTransform($0.transform) } ?? imageView.transform
        removeOutgoing(of: imageView, in: host)
        imageView.layer.removeAnimation(forKey: "opacity")
        imageView.layer.removeAnimation(forKey: "transform")

        let outgoing = OutgoingGlyph(image: imageView.image)
        outgoing.owner = imageView
        outgoing.tintColor = imageView.tintColor
        outgoing.contentMode = imageView.contentMode
        outgoing.preferredSymbolConfiguration = imageView.preferredSymbolConfiguration
        outgoing.isUserInteractionEnabled = false
        outgoing.bounds = imageView.bounds
        outgoing.center = imageView.center
        outgoing.transform = fromTransform
        outgoing.alpha = fromAlpha
        host.insertSubview(outgoing, belowSubview: imageView)

        UIView.performWithoutAnimation {
            imageView.image = image
            imageView.alpha = 0
            imageView.transform = CGAffineTransform(scaleX: swapScale, y: swapScale)
        }
        leave(outgoing)
        UIView.animate(
            withDuration: arriveDuration, delay: arriveDelay, usingSpringWithDamping: arriveDamping,
            initialSpringVelocity: 0, options: [.allowUserInteraction]
        ) {
            imageView.alpha = 1
            imageView.transform = .identity
        }
    }

    /// No swap in flight: the copies gone, the glyph whole — a scale and
    /// fade still springing stops where it lands.
    private static func settleGlyph(_ imageView: UIImageView) {
        if let host = imageView.superview { removeOutgoing(of: imageView, in: host) }
        imageView.layer.removeAnimation(forKey: "opacity")
        imageView.layer.removeAnimation(forKey: "transform")
        imageView.alpha = 1
        imageView.transform = .identity
    }

    private static func removeOutgoing(of owner: UIView, in host: UIView) {
        for case let copy as OutgoingGlyph in host.subviews where copy.owner === owner {
            copy.removeFromSuperview()
        }
    }

    // MARK: - A button

    /// Shows a new glyph in a configured `button` by `site`'s motion:
    /// `change` puts it in the button's configuration.
    ///
    /// ⚠️ Call it outside `UIView.performWithoutAnimation`: the scale and
    /// fade is view animations.
    @discardableResult
    public static func swap(
        _ button: UIButton, site: Site, animated: Bool,
        reducesMotion: Bool = MotionPreference.reducesMotion,
        change: () -> Void
    ) -> Motion {
        let chosen = motion(for: site, animated: animated && button.imageView?.image != nil, reducesMotion: reducesMotion)
        settleButton(button)
        switch chosen {
        case .cut:
            button.configuration?.symbolContentTransition = nil
            UIView.performWithoutAnimation {
                change()
                button.layoutIfNeeded()
            }
        case .replace:
            button.configuration?.symbolContentTransition = replaceTransition
            change()
        case .crossFade:
            button.configuration?.symbolContentTransition = nil
            UIView.performWithoutAnimation {
                change()
                button.layoutIfNeeded()
            }
            crossFade(button)
        case .scaleAndFade:
            button.configuration?.symbolContentTransition = nil
            scaleAndFade(button, change: change)
        }
        return chosen
    }

    /// The scale and fade on a button: its own glyph view is the button's to
    /// lay out, so two copies over it play the swap — the old glyph leaving,
    /// the new one arriving — and the button's glyph shows again when the
    /// new one has landed. `change` updates the button with no animation.
    ///
    /// For a button that applies its glyph itself (`AppIconButton`).
    public static func scaleAndFade(_ button: UIButton, change: () -> Void) {
        settleButton(button)
        guard let before = button.imageView, let old = before.image else {
            UIView.performWithoutAnimation {
                change()
                button.layoutIfNeeded()
            }
            return
        }
        let from = before.convert(before.bounds, to: button)
        let oldTint = before.tintColor
        UIView.performWithoutAnimation {
            change()
            button.layoutIfNeeded()
        }
        guard let glyph = button.imageView, let new = glyph.image else { return }
        let to = glyph.convert(glyph.bounds, to: button)

        let outgoing = OutgoingGlyph(image: old)
        outgoing.tintColor = oldTint
        outgoing.frame = from
        let incoming = OutgoingGlyph(image: new)
        incoming.tintColor = glyph.tintColor
        incoming.frame = to
        incoming.alpha = 0
        incoming.transform = CGAffineTransform(scaleX: swapScale, y: swapScale)
        for copy in [outgoing, incoming] {
            copy.owner = button
            copy.contentMode = .center
            copy.isUserInteractionEnabled = false
            button.addSubview(copy)
        }
        glyph.alpha = 0
        leave(outgoing)
        UIView.animate(
            withDuration: arriveDuration, delay: arriveDelay, usingSpringWithDamping: arriveDamping,
            initialSpringVelocity: 0, options: [.allowUserInteraction]
        ) {
            incoming.alpha = 1
            incoming.transform = .identity
        } completion: { _ in
            // Overtaken by a newer swap, which has its own copies: leave it.
            guard incoming.superview != nil else { return }
            settleButton(button)
        }
    }

    /// No swap in flight on `button`: the copies gone, its glyph shown.
    private static func settleButton(_ button: UIButton) {
        removeOutgoing(of: button, in: button)
        button.imageView?.alpha = 1
    }

    // MARK: - The leaving glyph

    private static func leave(_ outgoing: UIView) {
        UIView.animate(withDuration: leaveDuration, delay: 0, options: [.curveEaseIn, .allowUserInteraction]) {
            outgoing.alpha = 0
            outgoing.transform = CGAffineTransform(scaleX: swapScale, y: swapScale)
        } completion: { _ in
            outgoing.removeFromSuperview()
        }
    }

    /// A glyph a swap draws for a moment: the old one leaving, or (on a
    /// button) the new one arriving.
    final class OutgoingGlyph: UIImageView {
        weak var owner: UIView?
    }

    #if DEBUG
    /// The swap's copies still standing for `view` (an image view's in its
    /// superview, a button's in itself) — none once a swap has ended.
    public static func debugCopies(of view: UIView) -> Int {
        let host = view is UIButton ? view : view.superview
        return host?.subviews.filter { ($0 as? OutgoingGlyph)?.owner === view }.count ?? 0
    }
    #endif
}
