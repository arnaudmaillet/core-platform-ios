import Testing
import UIKit
@testable import CoreNavigation

/// The stack's cross-dissolve (#2246): the outgoing navigation view fades as
/// a PICTURE laid over it, the change runs as a cut underneath, unanimated,
/// and the picture leaves once faded — so no live glass item (the search
/// field, Cancel's capsule) can redraw, refract the next screen or show its
/// caret during the fade.
@MainActor
@Suite(.serialized)
struct CrossDissolvePictureTests {
    /// A navigation controller in a host view, on screen.
    private func stack() -> (UIWindow, UIViewController, UINavigationController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let host = UIViewController()
        let navigation = UINavigationController(rootViewController: UIViewController())
        host.addChild(navigation)
        host.view.addSubview(navigation.view)
        navigation.view.frame = host.view.bounds
        navigation.didMove(toParent: host)
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        return (window, host, navigation)
    }

    private func pictures(in host: UIView, above container: UIView) -> [UIView] {
        guard let index = host.subviews.firstIndex(of: container) else { return [] }
        return Array(host.subviews[(index + 1)...])
    }

    @Test func theChangeRunsUnanimatedUnderAPictureOfTheOutgoingScreen() async throws {
        let (window, host, navigation) = stack()
        // A test host renders nothing, so a real snapshot comes back empty:
        // a plain view stands in for the picture.
        let previous = CrossDissolvePicture.make
        CrossDissolvePicture.make = { _ in UIView() }
        defer {
            CrossDissolvePicture.make = previous
            window.isHidden = true
        }
        let next = UIViewController()
        var animationsWereOn: Bool?
        navigation.crossDissolve(duration: 0.05) {
            animationsWereOn = UIView.areAnimationsEnabled
            navigation.pushViewController(next, animated: false)
        }
        #expect(animationsWereOn == false, "the change animated")
        #expect(navigation.topViewController === next, "the change didn't run at once, as a cut")
        let laid = pictures(in: host.view, above: navigation.view)
        #expect(laid.count == 1, "no picture over the navigation view: \(host.view.subviews)")
        #expect(laid.first?.frame == navigation.view.frame)
        #expect(laid.first?.isUserInteractionEnabled == false, "the picture takes touches")
        // Faded, then gone.
        for _ in 0..<200 where !pictures(in: host.view, above: navigation.view).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pictures(in: host.view, above: navigation.view).isEmpty, "the picture outlived the fade")
    }

    @Test func offScreenTheChangeSimplyRuns() {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let next = UIViewController()
        var ran = false
        navigation.crossDissolve { ran = true; navigation.pushViewController(next, animated: false) }
        #expect(ran)
        #expect(navigation.topViewController === next)
    }
}
