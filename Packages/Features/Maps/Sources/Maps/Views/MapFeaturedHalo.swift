import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The text marker the map's bubble speaks for (the text bubble, #2203, the
/// owner, 2026-11-09): a little larger, over its neighbours, and its bubble
/// round it (`MapTextBubbleView`). No ring and no wave: the bubble says
/// which marker it is (the owner, 2026-11-09).
///
/// One for a single marker and a group alike: each view holds one and
/// hands it its picture (`card`).
@MainActor
final class MapFeaturedHalo {
    /// How much larger the featured marker stands.
    static let scale: CGFloat = 1.22

    private(set) var isFeatured = false
    /// Whether its bubbles are the rounded ones (#2330, `-map-bubble-rounded`).
    let bubbleIsRounded: Bool

    init(bubbleIsRounded: Bool = MapTextBubbleView.roundsByDefault) {
        self.bubbleIsRounded = bubbleIsRounded
    }

    private var bubble: MapTextBubbleView?
    /// What the bubble says: the same again (the map moving) changes nothing.
    private var bubbleContent: MapTextBubbleView.Content?

    /// Features `card`, in `host`, or takes it back — its bubble with it.
    func set(_ featured: Bool, card: UIView, in host: UIView, animated: Bool) {
        guard featured != isFeatured else { return }
        isFeatured = featured
        // A marker no longer featured says nothing.
        if !featured { setBubble(nil, card: card, in: host, animated: animated) }
        let grown = featured ? CGAffineTransform(scaleX: Self.scale, y: Self.scale) : .identity
        guard animated, host.window != nil, !MotionPreference.reducesMotion else {
            card.transform = grown
            return
        }
        UIView.animate(springDuration: 0.45, bounce: featured ? 0.35 : 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            card.transform = grown
        }
    }

    /// Back to rest at once — a view going back to the pool.
    func reset(card: UIView) {
        bubble?.layer.removeAllAnimations()
        bubble?.removeFromSuperview()
        bubble = nil
        bubbleContent = nil
        guard isFeatured else { return }
        isFeatured = false
        card.transform = .identity
    }

    // MARK: - The bubble

    /// The bubble round the featured marker with `content`, or none.
    ///
    /// It starts as the marker's own circle, where it stands, and unfolds
    /// both ways; the marker slides to its LEFT end — always (the owner) —
    /// rounded (#2330), to its top-left corner — and the author and the
    /// words appear on its right as it opens. Centred
    /// on the marker's place, always — it may run off the screen, as the map
    /// does — and it moves with the map, as the marker does. Its glass
    /// materialises as it opens and dissolves as it folds: the system's own
    /// glass animation.
    ///
    /// `imagePipeline` loads a showcase card's photo (#2216).
    func setBubble(
        _ content: MapTextBubbleView.Content?, card: UIView, in host: UIView, animated: Bool,
        imagePipeline: ImagePipeline? = nil
    ) {
        let moves = animated && host.window != nil && !MotionPreference.reducesMotion
        guard let content else {
            bubbleContent = nil
            guard let leaving = bubble else { return }
            bubble = nil
            return fold(leaving, card: card, animated: moves)
        }
        if bubble != nil, content == bubbleContent { return }
        bubbleContent = content
        let shown = bubble ?? MapTextBubbleView(isRounded: bubbleIsRounded)
        let isNew = bubble == nil
        bubble = shown
        let grown = card.bounds.width * Self.scale
        UIView.performWithoutAnimation {
            shown.markerSide = grown
            shown.imagePipeline = imagePipeline
            shown.setContent(content)
            // Behind the marker, which rides in it.
            if shown.superview !== host || (host.subviews.firstIndex(of: shown) ?? 0) > (host.subviews.firstIndex(of: card) ?? 0) {
                host.insertSubview(shown, belowSubview: card)
            }
        }
        let size = shown.bounds.size
        let centre = card.center
        // Where the marker rides in the bubble: its left end's middle, or
        // (rounded, #2330) its top-left corner — the bubble still centred on
        // the marker's place.
        let inBubble = shown.markerCentre(for: size)
        let marker = CGPoint(x: centre.x - size.width / 2 + inBubble.x, y: centre.y - size.height / 2 + inBubble.y)
        let resting = CGAffineTransform(translationX: marker.x - card.center.x, y: marker.y - card.center.y)
            .scaledBy(x: Self.scale, y: Self.scale)
        guard isNew, moves else {
            UIView.performWithoutAnimation {
                shown.bounds = CGRect(origin: .zero, size: size)
                shown.center = centre
                shown.setWordsShown(true)
                shown.setGlass(true)
                shown.layoutIfNeeded()
            }
            card.transform = resting
            return
        }
        let folded = grown + 2 * MapTextBubbleView.markerPadding
        UIView.performWithoutAnimation {
            shown.bounds = CGRect(x: 0, y: 0, width: folded, height: folded)
            shown.center = card.center
            shown.setWordsShown(false)
            shown.setGlass(false)
            shown.layoutIfNeeded()
        }
        let options: UIView.AnimationOptions = [.allowUserInteraction, .beginFromCurrentState]
        // The glass materialises as the bubble opens out of the marker.
        UIView.animate(springDuration: 0.6, bounce: 0.15, options: options) {
            shown.setGlass(true)
            shown.bounds = CGRect(origin: .zero, size: size)
            shown.center = centre
            shown.layoutIfNeeded()
            card.transform = resting
        }
        UIView.animate(withDuration: 0.3, delay: 0.18, options: options) { shown.setWordsShown(true) }
    }

    /// The reverse: the words go, the marker slides home and the bubble
    /// folds back into its circle, its glass dissolving; then it is gone.
    private func fold(_ leaving: MapTextBubbleView, card: UIView, animated: Bool) {
        let home = isFeatured ? CGAffineTransform(scaleX: Self.scale, y: Self.scale) : .identity
        guard animated else {
            leaving.removeFromSuperview()
            card.transform = home
            return
        }
        let folded = leaving.markerSide + 2 * MapTextBubbleView.markerPadding
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) { leaving.setWordsShown(false) }
        UIView.animate(springDuration: 0.5, bounce: 0, options: [.beginFromCurrentState]) {
            leaving.bounds = CGRect(x: 0, y: 0, width: folded, height: folded)
            leaving.center = card.center
            leaving.layoutIfNeeded()
            leaving.setGlass(false)
            card.transform = home
        } completion: { _ in
            leaving.removeFromSuperview()
        }
    }

    /// The bubble's frame in its marker's view, while it shows: the whole
    /// bubble takes the marker's tap (the owner, 2026-11-09).
    var bubbleHitFrame: CGRect? {
        guard let bubble, !bubble.isHidden else { return nil }
        return bubble.frame
    }

    /// The post the bubble speaks for, while one shows.
    var bubblePostID: PostID? { bubble == nil ? nil : bubbleContent?.postID }

    var debugBubble: MapTextBubbleView? { bubble }
}
