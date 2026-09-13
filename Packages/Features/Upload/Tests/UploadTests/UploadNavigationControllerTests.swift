import Testing
import UIKit
@testable import Upload

/// Where the upload flow's back-swipe may begin.
///
/// ⚠️ **WHAT THIS SUITE DELIBERATELY DOES NOT COVER: DIRECTION.** An earlier
/// revision asserted that a leftward or mostly-vertical drag is not a back-swipe.
/// Those tests passed and the feature was broken, because the decision they
/// described cannot be taken where it was wired: the recogniser asks its delegate
/// **before the touch has moved**, so translation and velocity are both `(0,0)`
/// there — measured twice, once each way. Direction is the recogniser's own
/// business for the rest of the gesture, and that it behaves is verified with
/// injected drags on a device.
///
/// ⚠️ And nothing here proves the screen pops or refuses to: no unit test begins
/// a pan. These fix the one decision this code actually makes.
@MainActor
struct UploadNavigationControllerTests {
    private static let edge: CGFloat = 20

    // MARK: - Where the drag began

    @Test func aDragFromTheLeadingEdgeMayBeABackSwipe() {
        #expect(UploadNavigationController.allows(startX: 8, edgeWidth: Self.edge))
    }

    /// The whole point of this round: the gesture used to fire from anywhere on
    /// the screen, which is what Arnaud asked to stop.
    @Test func aDragFromMidScreenMayNot() {
        #expect(UploadNavigationController.allows(startX: 150, edgeWidth: Self.edge) == false)
    }

    @Test func theEdgeBandIncludesItsOwnBoundaryAndStopsThere() {
        #expect(UploadNavigationController.allows(startX: Self.edge, edgeWidth: Self.edge))
        #expect(UploadNavigationController.allows(startX: Self.edge + 1, edgeWidth: Self.edge) == false)
    }

    @Test func aTouchOnTheEdgeItselfCounts() {
        #expect(UploadNavigationController.allows(startX: 0, edgeWidth: Self.edge))
    }

    // MARK: - The gate is actually installed

    /// ⚠️ **THIS ONE GUARDS A DEFECT I KEEP REPEATING:** a decision written and
    /// never wired. The rule above is worth nothing unless the stack takes the
    /// delegate of the recogniser that actually pops — and on this flow that is
    /// NOT `interactivePopGestureRecognizer`, which is enabled and inert.
    ///
    /// ⚠️ It depends on UIKit creating that recogniser in a test window. If it
    /// fails here while a device behaves, the test is wrong about the
    /// environment — but it must fail LOUDLY rather than pass vacuously.
    @Test func theStackTakesTheRecogniserItMeansToGate() {
        let navigation = UploadNavigationController(rootViewController: UIViewController())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        navigation.pushViewController(UIViewController(), animated: false)
        window.layoutIfNeeded()

        #expect(navigation.debugGatesTheBackSwipe)
    }
}
