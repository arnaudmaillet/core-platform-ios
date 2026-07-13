import Testing
import UIKit
@testable import Feed

/// The background tap (play/pause) must not fire when the touch lands on an
/// interactive control or a declared interactive root, but must fire for taps
/// on the media/caption/background. (Today's chrome declares no roots — the
/// engagement rail is gone — so these exercise the seam with fixtures.)
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
}
