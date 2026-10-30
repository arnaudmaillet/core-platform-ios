import CoreModels
import Testing
import UIKit
@testable import Feed

/// The wheel folds with the like (#1872, the owner on a device): its emotes
/// fold into the like and come out of it, hanging on the like as drawn —
/// the liquidglass lab's recursive collapse and reveal.
@MainActor
struct SnapWheelFoldTests {
    private static let width: CGFloat = 45

    private func makeWheel() -> SnapShortcutRailView {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        let rail = SnapShortcutRailView(frame: CGRect(x: 200, y: 100, width: Self.width, height: 400))
        host.addSubview(rail)
        rail.setEmotes(Array(SnapShortcutRailView.reactionPool().prefix(9)))
        rail.bottomReservedInset = Self.width
        rail.layoutIfNeeded()
        return rail
    }

    private func shownCount(_ rail: SnapShortcutRailView) -> Int {
        rail.icons.count { $0.alpha > 0.01 }
    }

    /// Folded, no emote shows; revealed, the resting window is back.
    @Test func foldedTheEmotesAreGoneAndRevealedTheyAreBack() {
        let rail = makeWheel()
        #expect(shownCount(rail) >= SnapShortcutRailView.restingIconCount)
        rail.collapseEmotes(animated: false)
        rail.layoutIfNeeded()
        #expect(rail.fold.isCollapsed)
        #expect(shownCount(rail) == 0)
        #expect(!rail.isUserInteractionEnabled)
        rail.revealEmotes(animated: false)
        rail.layoutIfNeeded()
        #expect(!rail.fold.isCollapsed)
        #expect(shownCount(rail) >= SnapShortcutRailView.restingIconCount)
        #expect(rail.contentOffset.y == -rail.contentInset.top, "the reveal is from rest")
    }

    /// With no like to hang on, the wheel hides; with the like at rest it
    /// stands, untransformed.
    @Test func theWheelHangsOnTheLike() {
        let rail = makeWheel()
        var like: (centre: CGPoint, scale: CGFloat, alpha: CGFloat)?
        rail.follow = { like }
        rail.applyFollow()
        #expect(rail.alpha == 0, "the wheel stood with no like under it")
        // The like at rest: the pill's centre under the wheel's strip.
        let rest = CGPoint(x: rail.center.x, y: rail.frame.maxY - Self.width + Self.width / 2)
        like = (rest, 1, 1)
        #expect(!rail.applyFollow())
        #expect(rail.alpha == 1)
        #expect(rail.transform == .identity)
    }

    /// The like folding away (moved, at 0.2×): the wheel is carried, its
    /// like point landing on the like as drawn.
    @Test func theWheelIsCarriedByTheLike() {
        let rail = makeWheel()
        let rest = CGPoint(x: rail.center.x, y: rail.frame.maxY - Self.width / 2)
        let drawn = CGPoint(x: rest.x, y: rest.y + 80)
        rail.follow = { (drawn, 0.2, 0.5) }
        #expect(rail.applyFollow())
        let landed = rest.applying(
            CGAffineTransform(translationX: -rail.center.x, y: -rail.center.y)
                .concatenating(rail.transform)
                .concatenating(CGAffineTransform(translationX: rail.center.x, y: rail.center.y))
        )
        #expect(abs(landed.x - drawn.x) < 0.5 && abs(landed.y - drawn.y) < 0.5)
        #expect(rail.alpha == 1, "the like's own fade was taken")
    }

    /// In the page: a media page's comments fold the wheel with the column;
    /// a text page's do not.
    @Test func aMediaPagesCommentsFoldTheWheel() {
        let chrome = SnapChromeView(frame: SnapActionColumnLayoutTests.screen)
        chrome.setFixedInsets(SnapActionColumnLayoutTests.insets)
        chrome.configure(with: SnapActionColumnLayoutTests.mediaModel())
        chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true))
        chrome.layoutIfNeeded()
        #expect(chrome.debugGlassColumn.presentedFace(of: "like") != nil)
        chrome.setColumnCollapsed(true, animated: false)
        chrome.layoutIfNeeded()
        #expect(chrome.debugShortcutRail.fold.isCollapsed)
        #expect(chrome.debugGlassColumn.presentedFace(of: "like") == nil)
        chrome.setColumnCollapsed(false, animated: false)
        chrome.layoutIfNeeded()
        #expect(!chrome.debugShortcutRail.fold.isCollapsed)

        let text = SnapChromeView(frame: SnapActionColumnLayoutTests.screen)
        text.setFixedInsets(SnapActionColumnLayoutTests.insets)
        text.configure(with: SnapActionColumnLayoutTests.mediaModel(mediaURL: nil))
        text.layoutIfNeeded()
        text.setColumnCollapsed(true, animated: false)
        #expect(!text.debugShortcutRail.fold.isCollapsed, "a text page's wheel folded")
    }
}
