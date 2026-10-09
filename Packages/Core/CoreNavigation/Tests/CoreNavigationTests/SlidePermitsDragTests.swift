import Testing
import UIKit
@testable import CoreNavigation

/// The slide's location-aware veto (#691): an owner that is not a
/// `ZoomTransitionDestination` — a pushed profile — still decides by WHERE
/// the drag began and which way it goes.
@MainActor
struct SlidePermitsDragTests {
    private final class FakePan: UIPanGestureRecognizer {
        var fakeVelocity = CGPoint(x: 900, y: 0)
        var fakeLocation = CGPoint(x: 260, y: 400)
        var fakeTranslation = CGPoint(x: 60, y: 0)
        override func velocity(in view: UIView?) -> CGPoint { fakeVelocity }
        override func location(in view: UIView?) -> CGPoint { fakeLocation }
        override func translation(in view: UIView?) -> CGPoint { fakeTranslation }
    }

    private func rig() -> (InteractiveSlideDismissal, UINavigationController) {
        let screen = UIViewController()
        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.viewControllers = [nav.viewControllers[0], screen]
        let slide = InteractiveSlideDismissal()
        slide.attach(to: screen, axes: [.horizontal])
        slide.install(on: nav)
        return (slide, nav)
    }

    @Test func theVetoIsAskedAtTheDragsOriginAndCanRefuse() {
        let (slide, nav) = rig()
        var asked: [(CGPoint, ZoomDismissAxis)] = []
        var permitted = false
        slide.permitsDrag = { origin, axis, _ in
            asked.append((origin, axis))
            return permitted
        }
        let pan = FakePan()
        #expect(!slide.gestureRecognizerShouldBegin(pan), "a refused drag began")
        #expect(asked.count == 1)
        #expect(asked.first?.0 == CGPoint(x: 200, y: 400), "asked at the finger, not at the origin")
        #expect(asked.first?.1 == .horizontal)

        permitted = true
        #expect(slide.gestureRecognizerShouldBegin(pan))
        withExtendedLifetime(nav) {}
    }

    @Test func noVetoClaimsAsBefore() {
        let (slide, nav) = rig()
        #expect(slide.gestureRecognizerShouldBegin(FakePan()))
        withExtendedLifetime(nav) {}
    }
}
