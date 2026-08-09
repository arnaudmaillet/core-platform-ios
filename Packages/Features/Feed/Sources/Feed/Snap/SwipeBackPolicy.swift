import CoreGraphics

/// When a full-width rightward drag means "go back".
///
/// Pure, because these two rules are the whole feature and a real drag cannot
/// be synthesised here — the simulator accepts no injected touches. Reading
/// them as arithmetic is the only way they get checked at all.
enum SwipeBackPolicy {
    /// The horizontal component must clearly dominate before the gesture may
    /// begin.
    ///
    /// A comment list scrolls vertically under this gesture and a thumb is
    /// never perfectly straight, so a vertical scroll carries some sideways
    /// velocity with it. Requiring horizontal DOMINANCE — not merely presence
    /// — is what stops a scroll being read as a dismissal. Rightward only:
    /// leftward means nothing on this page.
    static let dominance: CGFloat = 1.5

    static func shouldBegin(velocity: CGPoint) -> Bool {
        velocity.x > 0 && abs(velocity.x) > abs(velocity.y) * dominance
    }

    /// Distance OR speed, so a short flick counts as much as a long drag —
    /// the same either/or the system's own pop uses.
    static let popDistance: CGFloat = 90
    static let popVelocity: CGFloat = 700

    static func shouldPop(translationX: CGFloat, velocityX: CGFloat) -> Bool {
        translationX > popDistance || velocityX > popVelocity
    }
}
