import CoreModels
import Testing
import UIKit
@testable import Feed

/// The wheel's glass capsule (#1872, part 2): who takes the touch, when it
/// is there, the bridge onto the like, and the return chevron.
@MainActor
struct SnapWheelCapsuleTests {
    private static let width: CGFloat = 45
    private static let like: CGFloat = 62

    /// A wheel 9 emotes deep over a like strip, its capsule hosted in a
    /// plain container (the column's glass in the app).
    private func makeWheel() -> (rail: SnapShortcutRailView, host: UIView) {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 600))
        let rail = SnapShortcutRailView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 400))
        host.addSubview(rail)
        rail.setEmotes(Array(SnapShortcutRailView.reactionPool().prefix(9)))
        rail.bottomReservedInset = Self.width
        rail.layoutIfNeeded()
        rail.capsule.likeHeight = Self.like
        rail.capsule.host = { host.addSubview($0) }
        return (rail, host)
    }

    private func scroll(_ rail: SnapShortcutRailView, steps: CGFloat) {
        rail.contentOffset.y = -rail.contentInset.top + steps * SnapShortcutRailView.step
        rail.layoutIfNeeded()
    }

    /// Hosted, the wheel lets every touch through and its pan lives on the
    /// capsule's glass; unhosted (the flight's replica), it is as before.
    @Test func theCapsuleTakesTheWheelsTouches() {
        let bare = SnapShortcutRailView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 400))
        #expect(bare.point(inside: CGPoint(x: 20, y: 300), with: nil))
        let (rail, _) = makeWheel()
        #expect(!rail.point(inside: CGPoint(x: 20, y: 300), with: nil))
        #expect(rail.panGestureRecognizer.view === rail.capsule.glass)
    }

    /// Active while the finger is down, lingering after it lifts, gone once
    /// the linger runs out.
    @Test func activeThenLingeringThenGone() {
        let (rail, _) = makeWheel()
        let capsule = rail.capsule
        #expect(!capsule.isWanted, "the capsule shows at rest")
        capsule.debugTouch(down: true)
        #expect(capsule.isWanted)
        capsule.debugTouch(down: false)
        #expect(capsule.isWanted, "the capsule left with the finger")
        #expect(capsule.debugIsLingering)
        capsule.debugExpireLinger()
        #expect(!capsule.isWanted)
    }

    /// The comments take the page: the capsule goes, and no touch brings it
    /// back until they close.
    @Test func dismissedTheCapsuleStaysAway() {
        let (rail, _) = makeWheel()
        let capsule = rail.capsule
        capsule.debugTouch(down: true)
        capsule.setDismissed(true)
        #expect(!capsule.isWanted)
        capsule.debugTouch(down: true)
        #expect(!capsule.isWanted)
        capsule.setDismissed(false)
        capsule.debugTouch(down: true)
        #expect(capsule.isWanted)
    }

    /// At rest the capsule wraps the resting window, the like's width, and
    /// stops over the fade above the like.
    @Test func atRestTheCapsuleWrapsTheRestingWindow() {
        let (rail, _) = makeWheel()
        let frame = rail.capsule.frameInRail
        let likeTop = rail.bounds.maxY - rail.bottomReservedInset
        #expect(frame.width == Self.width)
        #expect(abs(frame.maxY - (likeTop - SnapShortcutRailView.edgeFadeLength + SnapWheelCapsule.pad)) < 0.5)
        #expect(abs(frame.height - (SnapShortcutRailView.restingWindowHeight + 2 * SnapWheelCapsule.pad)) < 0.5)
        #expect(rail.capsule.likeCover == 0)
    }

    /// One step up, the bridge is whole: the capsule runs down to the like
    /// PILL's bottom and the like's glass has retracted inside it.
    @Test func oneStepUpTheBridgeReachesThePillsBottom() {
        let (rail, _) = makeWheel()
        scroll(rail, steps: 1)
        let likeTop = rail.bounds.maxY - rail.bottomReservedInset
        #expect(abs(rail.capsule.frameInRail.maxY - (likeTop + Self.like)) < 0.5)
        #expect(rail.capsule.likeCover == 1)
        #expect(rail.capsule.bridge == 1)
    }

    /// The chevron: the first next emote whole AND the capsule there.
    @Test func theChevronNeedsTheStepAndTheCapsule() {
        let (rail, _) = makeWheel()
        var shown: [Bool] = []
        rail.capsule.onReturnShown = { shown.append($0) }
        scroll(rail, steps: 1)
        #expect(!rail.capsule.returnShown, "a chevron with no capsule")
        rail.capsule.debugTouch(down: true)
        #expect(rail.capsule.returnShown)
        rail.capsule.debugTouch(down: false)
        rail.capsule.debugExpireLinger()
        #expect(!rail.capsule.returnShown, "the chevron outlived the capsule")
        #expect(shown == [true, false])
    }

    /// The like's face: the chevron while it shows, and its tap returns
    /// the wheel instead of staking.
    @Test func theLikeWearsTheChevronAndItsTapReturns() {
        let like = SnapRailBoostButton()
        var boosts = 0
        var returns = 0
        like.onBoost = { _ in boosts += 1 }
        like.onReturn = { returns += 1 }
        like.setShowsReturn(true)
        #expect(like.accessibilityLabel == "Back to the first shortcuts")
        like.sendActions(for: .primaryActionTriggered)
        #expect(returns == 1 && boosts == 0)
        like.setShowsReturn(false)
        like.sendActions(for: .primaryActionTriggered)
        #expect(returns == 1 && boosts == 1)
        #expect(like.accessibilityLabel == "Like")
    }
}
