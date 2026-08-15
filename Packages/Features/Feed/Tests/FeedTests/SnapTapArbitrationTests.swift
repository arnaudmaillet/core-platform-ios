import Testing
import UIKit
@testable import Feed

/// The background tap (play/pause) must not fire when the touch lands on an
/// interactive control or a declared interactive root, but must fire for taps
/// on the media/caption/background. The walk itself is exercised with
/// fixtures; the chrome's real declaration (the shortcut rail) is pinned
/// separately below.
@MainActor
struct SnapTapArbitrationTests {
    @Test func controlTouchesAndInteractiveRootsAreRejected() {
        let contentView = UIView()   // stands in for the cell's contentView (stopAt)
        let rail = UIView()          // a synthetic interactive root
        contentView.addSubview(rail)
        let button = UIButton()
        rail.addSubview(button)
        let insideRail = UIView()
        rail.addSubview(insideRail)

        // A control anywhere in the tree → interactive (rail button).
        #expect(SnapFeedCell.isInteractiveTouch(button, interactiveRoots: [rail], stopAt: contentView) == true)
        // A plain view nested under an interactive root → interactive.
        #expect(SnapFeedCell.isInteractiveTouch(insideRail, interactiveRoots: [rail], stopAt: contentView) == true)
    }

    @Test func backgroundTouchesToggle() {
        let contentView = UIView()
        let rail = UIView()
        contentView.addSubview(rail)
        let caption = UILabel()      // non-interactive background content
        contentView.addSubview(caption)

        // A caption/background tap → not interactive → toggles playback.
        #expect(SnapFeedCell.isInteractiveTouch(caption, interactiveRoots: [rail], stopAt: contentView) == false)
        // A nil hit view → allowed.
        #expect(SnapFeedCell.isInteractiveTouch(nil, interactiveRoots: [rail], stopAt: contentView) == false)
    }

    @Test func chromeDeclaresItsInteractiveRoots() {
        // The chrome's real declaration: touches on the shortcut wheel (or
        // its fixed "+" anchor — rail territory, present in BOTH engagement
        // states) use the wheel, and taps on any comments surface
        // (empty-state pill, subtitle zone, ticker band) open the
        // engagement — none of them toggles playback. Each surface is
        // hidden unless its content gate admits it, and hidden views
        // receive no touches, so play/pause keeps the whole page wherever
        // no surface is showing.
        let chrome = SnapChromeView()
        #expect(chrome.interactionRoots.count == 5)
        #expect(chrome.interactionRoots.contains(where: { $0 is SnapShortcutRailView }))
        #expect(chrome.interactionRoots.contains(where: { $0 is SnapRailBoostButton }))
        #expect(chrome.interactionRoots.contains(where: { $0 is SnapCommentEmptyStateView }))
        #expect(chrome.interactionRoots.contains(where: { $0 is SnapSubtitleView }))
        #expect(chrome.interactionRoots.contains(where: { $0 is SnapCommentTickerView }))
    }

    @Test func touchesInsideCommentSurfacesAreInteractive() {
        // A touch landing on a comment surface's descendant (a cue label, a
        // conveying bubble) walks up to the surface root and is claimed —
        // the whole zone is the thumb target, not just the glyphs.
        let contentView = UIView()
        let subtitle = SnapSubtitleView()
        let inner = UILabel()
        subtitle.addSubview(inner)
        contentView.addSubview(subtitle)
        #expect(SnapFeedCell.isInteractiveTouch(inner, interactiveRoots: [subtitle], stopAt: contentView) == true)
    }
}
