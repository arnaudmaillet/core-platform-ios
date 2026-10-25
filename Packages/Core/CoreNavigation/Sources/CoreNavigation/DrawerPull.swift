import DesignSystem
import UIKit

/// The shell's drawer as "page −1" of the tab roots' pagers (#1739, the owner
/// 2026-10-25): For You, Messages and Profile page between tabs horizontally,
/// and pulling past the FIRST tab opens the notifications drawer with that
/// same gesture — the tabs' own pan, with the priority it already has over
/// the page's content.
///
/// A root hands its pager this relay (`leadingPullTarget = DrawerPull.shared`);
/// the shell registers its drawer here (`drawer`). The relay is stable, so a
/// root built before the shell — or rebuilt after a sign-in — needs no wiring
/// from the outside; nothing registered, every pull is refused and the pager
/// rubber-bands as usual.
@MainActor
public final class DrawerPull: LeadingPullTarget {
    public static let shared = DrawerPull()

    /// The drawer the pulls drive, or nil.
    public weak var drawer: (any LeadingPullTarget)?

    public init() {}

    public func beginLeadingPull() -> Bool { drawer?.beginLeadingPull() ?? false }
    public func updateLeadingPull(_ distance: CGFloat) { drawer?.updateLeadingPull(distance) }
    public func endLeadingPull(velocity: CGFloat) { drawer?.endLeadingPull(velocity: velocity) }
    public func cancelLeadingPull() { drawer?.cancelLeadingPull() }
}
