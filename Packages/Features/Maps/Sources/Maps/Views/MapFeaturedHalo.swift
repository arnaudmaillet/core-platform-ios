import DesignSystem
import UIKit

/// The marker the map's text-post card speaks for (`-map-text-card`, the
/// owner 2026-11-08: "which marker is it?"): a little larger, over its
/// neighbours, a ring of the brand's around it — and, as it takes the card,
/// one wave leaving the ring. Then it rests: no endless decoration on an
/// untouched map (#580).
///
/// One for a single marker and a group alike: each view holds one and
/// hands it its picture (`card`).
@MainActor
final class MapFeaturedHalo {
    /// How much larger the featured marker stands.
    static let scale: CGFloat = 1.22
    /// The ring's stroke, and its gap outside the grown marker.
    static let ringWidth: CGFloat = 2.5
    static let ringGap: CGFloat = 4

    private(set) var isFeatured = false
    private var ring: UIView?

    /// Features `card`, in `host`, or takes it back.
    func set(_ featured: Bool, card: UIView, in host: UIView, animated: Bool) {
        guard featured != isFeatured else { return }
        isFeatured = featured
        let ring = ringView(in: host, below: card)
        place(ring, around: card)
        ring.layer.borderColor = Palette.tint.resolvedColor(with: host.traitCollection).cgColor
        let grown = featured ? CGAffineTransform(scaleX: Self.scale, y: Self.scale) : .identity
        guard animated, host.window != nil, !MotionPreference.reducesMotion else {
            card.transform = grown
            ring.alpha = featured ? 1 : 0
            ring.transform = .identity
            return
        }
        if featured { ring.transform = CGAffineTransform(scaleX: 0.7, y: 0.7) }
        UIView.animate(springDuration: 0.45, bounce: featured ? 0.35 : 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            card.transform = grown
            ring.alpha = featured ? 1 : 0
            ring.transform = featured ? .identity : CGAffineTransform(scaleX: 0.85, y: 0.85)
        }
        if featured { pulse(ring) }
    }

    /// Back to rest at once — a view going back to the pool.
    func reset(card: UIView) {
        guard isFeatured else { return }
        isFeatured = false
        card.transform = .identity
        ring?.alpha = 0
        ring?.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    private func ringView(in host: UIView, below card: UIView) -> UIView {
        if let ring { return ring }
        let ring = UIView()
        ring.isUserInteractionEnabled = false
        ring.backgroundColor = .clear
        ring.layer.borderWidth = Self.ringWidth
        ring.alpha = 0
        host.insertSubview(ring, belowSubview: card)
        self.ring = ring
        return ring
    }

    /// A circle a few points outside the grown marker.
    private func place(_ ring: UIView, around card: UIView) {
        let side = card.bounds.width * Self.scale + 2 * Self.ringGap
        UIView.performWithoutAnimation {
            ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            ring.center = card.center
            ring.layer.cornerRadius = side / 2
        }
    }

    /// One wave leaves the ring (the owner: one is enough), then it rests.
    private func pulse(_ ring: UIView) {
        let wave = CAShapeLayer()
        let bounds = ring.bounds
        wave.frame = bounds
        wave.path = UIBezierPath(ovalIn: bounds).cgPath
        wave.fillColor = UIColor.clear.cgColor
        wave.strokeColor = ring.layer.borderColor
        wave.lineWidth = Self.ringWidth
        wave.opacity = 0
        ring.layer.addSublayer(wave)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.7
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.9
        group.repeatCount = 1
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { wave.removeFromSuperlayer() }
        wave.add(group, forKey: "pulse")
        CATransaction.commit()
    }

    var debugRingShown: Bool { (ring?.alpha ?? 0) > 0 }
}
