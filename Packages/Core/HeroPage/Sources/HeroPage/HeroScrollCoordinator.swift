import CoreGraphics
import DesignSystem

/// The hero page's scroll arithmetic (#1651, slice #1652): where the floating
/// header stands for a page's offset, when its identity has faded, where the
/// release comes to rest — one value, so every page kind reads the same
/// numbers instead of keeping its own copy (the place page's had drifted: its
/// identity faded over 80 pt, the profile's over 90).
///
/// The header is NOT in a scroll view. It floats over the pages and is moved
/// by its top constraint from the active page's offset — `travelled`, 0 at
/// rest, growing as the content goes up — so the banner, the identity block
/// and whatever the page docks travel as one with the content.
///
/// ```
///   0             ── rest: the whole header on screen
///   dockLine      ── the header stops climbing: what it keeps (a slot,
///                    `dockedSlot`) meets the navigation bar
///   contentFloor  ── the first row of content directly under the bar
/// ```
///
/// Pure: everything it answers is a function of what it was made with.
public struct HeroScrollCoordinator: Equatable, Sendable {
    /// The header's height at rest — what the pages are inset by.
    public var headerHeight: CGFloat
    /// The navigation bar's bottom: the safe area's top.
    public var safeTop: CGFloat
    /// What the header still shows once docked, under the bar: a selector's
    /// slot, or nothing.
    public var dockedSlot: CGFloat

    public init(headerHeight: CGFloat, safeTop: CGFloat, dockedSlot: CGFloat = 0) {
        self.headerHeight = headerHeight
        self.safeTop = safeTop
        self.dockedSlot = dockedSlot
    }

    /// How far the header travels before it docks: the dock line.
    public var dockLine: CGFloat {
        max(0, headerHeight - dockedSlot - safeTop)
    }

    /// How far a page must be able to scroll for its first row to sit
    /// directly under the bar.
    ///
    /// ⚠️ A SLOT FURTHER THAN THE DOCK LINE, and the difference is a bug
    /// fixed once (the profile's `contentTravel`): the pages are inset by the
    /// header's full height, slot included, but once the header docks that
    /// slot is empty — its occupant is in the bar. Docking and the content's
    /// floor are two questions with two answers.
    public var contentFloor: CGFloat {
        max(0, headerHeight - safeTop)
    }

    /// The header's top constraint for `travelled`: it follows the content
    /// up to the dock line and stops there.
    ///
    /// ⚠️ NEGATIVE TRAVEL IS NOT CLAMPED, and that is the point: a pull past
    /// the top carries the header DOWN by exactly the overscroll, so the
    /// banner, the identity and the content stretch as one.
    public func headerTop(travelled: CGFloat) -> CGFloat {
        -min(travelled, dockLine)
    }

    /// How visible the identity block is (`HeaderIdentityFade`): gone
    /// exactly at the dock line.
    public func identityAlpha(travelled: CGFloat) -> CGFloat {
        HeaderIdentityFade.alpha(travelled: travelled, dockLine: dockLine)
    }

    /// Whether the navigation bar wears its at-rest look: only at the top.
    public func barIsAtRest(travelled: CGFloat) -> Bool {
        travelled <= 0
    }

    /// Whether an element of the header whose foot stands at `foot` (in the
    /// header's own space, at rest) has gone under the bar for `travelled`
    /// — the profile's action tray, which hands the bar its identity pill.
    ///
    /// ⚠️ AT REST NOTHING IS UNDER THE BAR, whatever the frames say: a push
    /// reads them before the header has laid out (a foot at 0), and the pill
    /// showed over a profile that had not moved (the owner, on a device,
    /// 2026-10-15).
    public func isUnderBar(foot: CGFloat, travelled: CGFloat) -> Bool {
        guard travelled > 0, foot > 0 else { return false }
        return foot - min(travelled, dockLine) <= safeTop
    }

    /// Where a release comes to rest while the header is on screen, in the
    /// header's travelled space: the top, an optional catching notch (a band
    /// card's avatar just under the bar, #1208), and the first row of
    /// content. A notch at or past the first row is no notch.
    ///
    /// Past the last detent the offset belongs to the list and is left alone.
    public func detents(notch: CGFloat? = nil) -> [CGFloat] {
        var detents: [CGFloat] = [0]
        if let notch, notch > 0, notch < contentFloor { detents.append(notch) }
        if contentFloor > 0 { detents.append(contentFloor) }
        return detents
    }
}
