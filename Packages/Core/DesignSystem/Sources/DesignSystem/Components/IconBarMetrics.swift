import UIKit

/// The shape both icon bars are cut to.
///
/// ⚠️ **ONE DEFINITION, TWO USERS — AND THE TWO SIT SIDE BY SIDE.** Upload's
/// editor toolbar carries an `IconActionBar` at the leading edge and an
/// `IconSelectorBar` beside it, on the same baseline, inside the same bar. A
/// segment side of 36 in one file and 36 in the other is not "the same number
/// twice": it is two numbers that happen to agree today, and the first time one
/// of them is nudged the two bubbles stop lining up — visibly, because they are
/// adjacent. `ChipScrollView` carries the same note for the same reason, and this
/// makes the third statement of the rule in this package.
///
/// Deliberately NOT public: both tenants are in this module, and a metric a
/// feature can read is a metric a feature can build its own bar out of.
enum IconBarMetrics {
    /// The square each icon occupies. 36 is `SoundPillView`'s height, and all
    /// three sit side by side in Upload's toolbar — a different number would
    /// misalign them by a visible point.
    static let segmentSide: CGFloat = 36

    static let interSegmentSpacing: CGFloat = 2

    /// Capsule edge to the ink inside it.
    ///
    /// ⚠️ **ZERO INSIDE A BAR, AND THAT IS NOT A SMALLER NUMBER PICKED BY EYE.**
    /// A toolbar's platter is 4pt larger than the view it hosts, so a clearance
    /// of our own stacks on top of it and the ink reads 6pt off the edge where
    /// `PagedTabBar`, which zeroes its own padding for exactly this reason, reads
    /// 4. See `IconSelectorBar.suppressesBackdrop`.
    static let clearance: CGFloat = 2

    static var capsuleHeight: CGFloat { segmentSide }

    /// The tint behind the item that is chosen, or whose panel is open.
    static let lensTint = UIColor.label.withAlphaComponent(0.18)

    /// How wide a bar of `count` segments wants to be.
    static func intrinsicWidth(count: Int, outerInset: CGFloat) -> CGFloat {
        let count = CGFloat(max(count, 1))
        return count * segmentSide
            + max(0, count - 1) * interSegmentSpacing
            + outerInset * 2
    }
}
