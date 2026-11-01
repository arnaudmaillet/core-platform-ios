import Testing
import UIKit
@testable import DesignSystem

/// `BottomEdgeBlurView` (#1002): one band per navigation controller, over its
/// screens and under its bars, the inert scroll view that owns the blur, the
/// style a screen lends it, and the arithmetic that makes it as tall as the
/// status band. The look itself — UIKit's `.soft` bottom edge, 62pt — was
/// measured on the simulator (`-status-bar-blur-audit` prints `bottom=`);
/// these pin the rules it rests on.
///
/// Windows are local and never made visible (`visible-window-suite-release`).
@MainActor
struct BottomEdgeBlurViewTests {

    private func makeStack() -> UINavigationController {
        let stack = UINavigationController(rootViewController: UIViewController())
        stack.loadViewIfNeeded()
        stack.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        return stack
    }

    /// A stack in a window, laid out, so its screens' views are in place.
    private func makeStackInWindow() -> (UINavigationController, UIWindow) {
        let stack = UINavigationController(rootViewController: UIViewController())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = stack
        window.layoutIfNeeded()
        return (stack, window)
    }

    // MARK: Install — over the screens, under the bars

    @Test func installingPutsTheBandInTheStack() {
        let stack = makeStack()
        let band = BottomEdgeBlurView.install(in: stack)
        #expect(band.superview === stack.view)
        #expect(BottomEdgeBlurView.installed(in: stack) === band)
        #expect(band.frame == stack.view.bounds)
    }

    @Test func installingTwiceKeepsOneBand() {
        let stack = makeStack()
        let first = BottomEdgeBlurView.install(in: stack)
        let second = BottomEdgeBlurView.install(in: stack)
        #expect(first === second)
        #expect(stack.view.subviews.filter { $0 is BottomEdgeBlurView }.count == 1)
    }

    @Test func aStackWithoutOneHasNone() {
        #expect(BottomEdgeBlurView.installed(in: makeStack()) == nil)
        #expect(BottomEdgeBlurView.installed(in: nil) == nil)
    }

    /// Directly above the content (the stack's first subview, which hosts
    /// every screen), and under the navigation bar.
    @Test func itSitsOverTheScreensAndUnderTheNavigationBar() {
        let (stack, window) = makeStackInWindow()
        let band = BottomEdgeBlurView.install(in: stack)
        window.layoutIfNeeded()
        let subviews = stack.view.subviews
        let bandIndex = subviews.firstIndex(of: band)
        #expect(bandIndex == 1)
        #expect(Self.isContentHost(subviews[0]))
        let barIndex = subviews.firstIndex(of: stack.navigationBar)
        #expect(barIndex.map { $0 > 1 } == true)
    }

    /// A pushed screen slides in under the band, and what UIKit adds to the
    /// stack's view later — the toolbar, the floating container that hosts
    /// its glass items on iOS 26/27 — is drawn over it.
    @Test func pushedScreensAndLaterBarsKeepTheirPlace() {
        let (stack, window) = makeStackInWindow()
        let band = BottomEdgeBlurView.install(in: stack)
        let pushed = UIViewController()
        stack.pushViewController(pushed, animated: false)
        window.layoutIfNeeded()
        let floatingBarHost = UIView()
        stack.view.addSubview(floatingBarHost)
        let subviews = stack.view.subviews
        let bandIndex = subviews.firstIndex(of: band) ?? -1
        #expect(Self.isContentHost(subviews[0]))
        #expect(bandIndex == 1)
        #expect((subviews.firstIndex(of: floatingBarHost) ?? -1) > bandIndex)
    }

    @Test func itTakesNoTouches() {
        let (stack, window) = makeStackInWindow()
        let band = BottomEdgeBlurView.install(in: stack)
        window.layoutIfNeeded()
        #expect(!band.isUserInteractionEnabled)
        #expect(!band.pocket.isUserInteractionEnabled)
        // A touch in the band's 62pt never lands on it — the band answers no
        // hit test, and the stack's view hands the touch to what is under it
        // (or to nothing: a window never made visible may not have put the
        // screen in yet, which is what CI's host does).
        let point = CGPoint(x: band.bounds.midX, y: band.bounds.maxY - 5)
        #expect(band.hitTest(point, with: nil) == nil)
        let hit = stack.view.hitTest(band.convert(point, to: stack.view), with: nil)
        #expect(hit.map { $0.isDescendant(of: band) } != true)
    }

    // MARK: The inert scroll view and the pocket

    /// ⚠️ Two on-screen scroll views answering the status-bar tap means NEITHER
    /// scrolls: the screen's real list would lose tap-to-top.
    @Test func theScrollViewNeverAnswersTheStatusBarTap() {
        #expect(!BottomEdgeBlurView().edgeScrollView.scrollsToTop)
    }

    @Test func theScrollViewNeverScrollsNorTakesTouches() {
        let band = BottomEdgeBlurView()
        #expect(!band.edgeScrollView.isScrollEnabled)
        #expect(!band.edgeScrollView.isUserInteractionEnabled)
    }

    /// VoiceOver never lands on it — not the band, not the label the pocket
    /// needs for UIKit to draw the effect.
    @Test func itIsInvisibleToAccessibility() {
        let band = BottomEdgeBlurView()
        #expect(band.accessibilityElementsHidden)
        #expect(band.pocket.accessibilityElementsHidden)
        #expect(!band.element.isAccessibilityElement)
        #expect(band.element.textColor == .clear)
    }

    // MARK: Geometry — the status band's height

    /// UIKit's soft effect is 60pt; the scroll view is scaled to make it the
    /// status band's 62pt.
    @Test func theScaleMakesTheEffectTheStatusBandsHeight() {
        let scale = BottomEdgeBlurView.scale(statusBandHeight: 62)
        #expect(abs(scale * BottomEdgeBlurView.softEdgeHeight - 62) < 0.001)
    }

    /// Landscape: no status bar, no inset, no band.
    @Test func noStatusBandMeansNoBand() {
        #expect(BottomEdgeBlurView.scale(statusBandHeight: 0) == 0)
        #expect(BottomEdgeBlurView.scale(statusBandHeight: -4) == 0)
    }

    /// The height the band reports is the height it draws, whatever the
    /// status band: 62 (Dynamic Island), 54, 47 and 20 (SE) points.
    @Test func theBandDrawsTheHeightItReports() {
        for statusBand: CGFloat in [62, 54, 47, 20] {
            #expect(abs(BottomEdgeBlurView.scale(statusBandHeight: statusBand) * BottomEdgeBlurView.softEdgeHeight
                - statusBand) < 0.001)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let band = BottomEdgeBlurView()
        band.frame = window.bounds
        window.addSubview(band) // never made visible, as this suite's other windows
        band.layoutIfNeeded()
        #expect(band.pocket.frame.height == BottomEdgeBlurView.bandHeight(in: window))
        #expect(BottomEdgeBlurView.bandHeight(in: nil) == 0)
    }

    /// A fitted height clears the band (#1995): its part over the bottom
    /// safe area, plus the gap — the Rewards sheet's collapsed detent.
    @Test func aFittedHeightClearsTheBand() {
        // A Dynamic Island iPhone: 62 pt band, 34 pt home indicator.
        #expect(BottomEdgeBlurView.clearance(band: 62, bottomInset: 34, gap: 8) == 36)
        // An SE: 20 pt band, no bottom inset.
        #expect(BottomEdgeBlurView.clearance(band: 20, bottomInset: 0, gap: 8) == 28)
        // No band (landscape), or a band under the inset: the gap alone.
        #expect(BottomEdgeBlurView.clearance(band: 0, bottomInset: 0, gap: 8) == 8)
        #expect(BottomEdgeBlurView.clearance(band: 20, bottomInset: 34, gap: 8) == 8)
        // So the control's bottom stands at least the band above the edge.
        for (band, inset): (CGFloat, CGFloat) in [(62, 34), (20, 0)] {
            #expect(BottomEdgeBlurView.clearance(band: band, bottomInset: inset, gap: 8) + inset >= band)
        }
    }

    /// Off-window there is no status band to mirror, so the view stays hidden.
    @Test func offWindowItIsHidden() {
        let band = BottomEdgeBlurView()
        band.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        band.layoutIfNeeded()
        #expect(band.isHidden)
    }

    // MARK: Style

    @Test func aScreenLendsItsStyleAndTakesItBack() {
        let band = BottomEdgeBlurView()
        let feed = NSObject()
        band.lendStyle(.dark, from: feed)
        #expect(band.overrideUserInterfaceStyle == .dark)
        band.returnStyle(from: feed)
        #expect(band.overrideUserInterfaceStyle == .unspecified)
        #expect(band.styleLender == nil)
    }

    @Test func onlyTheCurrentLenderTakesTheStyleBack() {
        let band = BottomEdgeBlurView()
        let leaving = NSObject()
        let arriving = NSObject()
        band.lendStyle(.light, from: leaving)
        band.lendStyle(.dark, from: arriving)
        band.returnStyle(from: leaving)
        #expect(band.overrideUserInterfaceStyle == .dark)
        #expect(band.styleLender === arriving)
    }

    @Test func aReleasedLenderLeavesNoStyleBehind() {
        let band = BottomEdgeBlurView()
        band.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        do {
            let feed = NSObject()
            band.lendStyle(.dark, from: feed)
        }
        band.setNeedsLayout()
        band.layoutIfNeeded()
        #expect(band.overrideUserInterfaceStyle == .unspecified)
    }

    // MARK: Helpers

    /// The view that hosts a stack's screens, `UINavigationTransitionView`.
    /// (A window never made visible does not put the screens' views in it,
    /// so the class is the check.)
    private static func isContentHost(_ view: UIView) -> Bool {
        String(describing: type(of: view)).contains("TransitionView")
    }
}
