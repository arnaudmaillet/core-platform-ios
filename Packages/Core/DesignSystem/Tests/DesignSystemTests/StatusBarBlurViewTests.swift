import Testing
import UIKit
@testable import DesignSystem

/// `StatusBarBlurView`: one band per WINDOW, over everything the app draws in
/// it — every root, every pushed screen, every presentation — the inert scroll
/// view that owns the blur, the style a screen lends it, and the band
/// geometry. The look itself — the Map's edge effect, filter for filter — was
/// established on simulator dumps (`-status-bar-blur-audit`); these pin the
/// rules it rests on.
///
/// Windows are local and never made visible (`visible-window-suite-release`).
@MainActor
struct StatusBarBlurViewTests {

    private func makeWindow(root: UIViewController? = nil) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = root
        return window
    }

    // MARK: Install — the window, once

    @Test func installingPutsTheBandInTheWindow() {
        let window = makeWindow()
        let blur = StatusBarBlurView.install(in: window)
        #expect(blur.superview === window)
        #expect(StatusBarBlurView.installed(in: window) === blur)
    }

    @Test func installingTwiceKeepsOneBand() {
        let window = makeWindow()
        let first = StatusBarBlurView.install(in: window)
        let second = StatusBarBlurView.install(in: window)
        #expect(first === second)
        #expect(window.subviews.filter { $0 is StatusBarBlurView }.count == 1)
    }

    @Test func aWindowWithoutOneHasNone() {
        #expect(StatusBarBlurView.installed(in: makeWindow()) == nil)
        #expect(StatusBarBlurView.installed(in: nil) == nil)
    }

    /// It covers the whole window and follows its size, so its scroll view
    /// gets the window's safe area — what UIKit sizes the effect from.
    @Test func itCoversTheWholeWindow() {
        let window = makeWindow()
        let blur = StatusBarBlurView.install(in: window)
        #expect(blur.frame == window.bounds)
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        window.layoutIfNeeded()
        blur.layoutIfNeeded()
        #expect(blur.frame == window.bounds)
        #expect(blur.edgeScrollView.frame == blur.bounds)
    }

    // MARK: Over every screen

    /// A tab root, then a pushed screen: the band stays the window's, drawn
    /// over the stack, and no screen carries one of its own.
    @Test func itIsOverEveryRootAndEveryPushedScreen() {
        let tabs = UITabBarController()
        let stack = UINavigationController(rootViewController: UIViewController())
        tabs.viewControllers = [stack, UINavigationController(rootViewController: UIViewController())]
        let window = makeWindow(root: tabs)
        window.layoutIfNeeded()
        let blur = StatusBarBlurView.install(in: window)
        for index in 0..<2 {
            tabs.selectedIndex = index
            window.layoutIfNeeded()
            #expect(blur.superview === window)
            #expect(Self.drawsOverEverySibling(blur, in: window))
        }
        tabs.selectedIndex = 0
        stack.pushViewController(UIViewController(), animated: false)
        window.layoutIfNeeded()
        #expect(blur.superview === window)
        #expect(Self.drawsOverEverySibling(blur, in: window))
        #expect(!Self.containsBand(tabs.view))
    }

    /// UIKit adds a presentation as a LATER window subview — the band must
    /// still be drawn over it. (A real modal never completes in a package
    /// test host, so the container is added the way UIKit adds it.)
    @Test func itIsOverAPresentationAddedAfterIt() {
        let window = makeWindow(root: UIViewController())
        let blur = StatusBarBlurView.install(in: window)
        let presentationContainer = UIView(frame: window.bounds)
        window.addSubview(presentationContainer)
        #expect(window.subviews.last === presentationContainer)
        #expect(Self.drawsOverEverySibling(blur, in: window))
        // …and over the content a hero flight parks in the window.
        let flightChrome = UIView(frame: window.bounds)
        window.addSubview(flightChrome)
        window.bringSubviewToFront(flightChrome)
        #expect(Self.drawsOverEverySibling(blur, in: window))
    }

    /// A root swap (sign-in, sign-out) replaces the root's view only.
    @Test func itSurvivesARootSwap() {
        let window = makeWindow(root: UIViewController())
        let blur = StatusBarBlurView.install(in: window)
        window.rootViewController = UINavigationController(rootViewController: UIViewController())
        window.layoutIfNeeded()
        #expect(blur.superview === window)
        #expect(Self.drawsOverEverySibling(blur, in: window))
    }

    @Test func itTakesNoTouches() {
        let window = makeWindow(root: UIViewController())
        let blur = StatusBarBlurView.install(in: window)
        #expect(!blur.isUserInteractionEnabled)
        #expect(window.hitTest(CGPoint(x: 200, y: 20), with: nil) !== blur)
    }

    // MARK: Style

    /// The snap feed lends its settled page's style; the band wears it until
    /// the same screen takes it back.
    @Test func aScreenLendsItsStyleAndTakesItBack() {
        let blur = StatusBarBlurView()
        let feed = NSObject()
        blur.lendStyle(.dark, from: feed)
        #expect(blur.overrideUserInterfaceStyle == .dark)
        blur.lendStyle(.unspecified, from: feed)
        #expect(blur.overrideUserInterfaceStyle == .unspecified)
        blur.lendStyle(.dark, from: feed)
        blur.returnStyle(from: feed)
        #expect(blur.overrideUserInterfaceStyle == .unspecified)
        #expect(blur.styleLender == nil)
    }

    /// A screen leaving late never undoes the style of the one over it.
    @Test func onlyTheCurrentLenderTakesTheStyleBack() {
        let blur = StatusBarBlurView()
        let leaving = NSObject()
        let arriving = NSObject()
        blur.lendStyle(.light, from: leaving)
        blur.lendStyle(.dark, from: arriving)
        blur.returnStyle(from: leaving)
        #expect(blur.overrideUserInterfaceStyle == .dark)
        #expect(blur.styleLender === arriving)
    }

    /// A lender released without handing the style back leaves nothing
    /// pinned at the next layout.
    @Test func aReleasedLenderLeavesNoStyleBehind() {
        let blur = StatusBarBlurView()
        blur.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        do {
            let feed = NSObject()
            blur.lendStyle(.dark, from: feed)
        }
        blur.setNeedsLayout()
        blur.layoutIfNeeded()
        #expect(blur.overrideUserInterfaceStyle == .unspecified)
    }

    // MARK: The inert scroll view

    /// ⚠️ Two on-screen scroll views answering the status-bar tap means NEITHER
    /// scrolls: the screen's real list would lose tap-to-top.
    @Test func theScrollViewNeverAnswersTheStatusBarTap() {
        #expect(!StatusBarBlurView().edgeScrollView.scrollsToTop)
    }

    @Test func theScrollViewNeverScrollsNorTakesTouches() {
        let blur = StatusBarBlurView()
        #expect(!blur.edgeScrollView.isScrollEnabled)
        #expect(!blur.edgeScrollView.isUserInteractionEnabled)
    }

    /// VoiceOver never lands on it — not the band, not its scroll view.
    @Test func itIsInvisibleToAccessibility() {
        let blur = StatusBarBlurView()
        #expect(blur.accessibilityElementsHidden)
        #expect(blur.edgeScrollView.accessibilityElementsHidden)
        #expect(!blur.edgeScrollView.isAccessibilityElement)
    }

    /// The blur IS the top edge effect left as UIKit makes it — `.automatic`,
    /// shown — the style the Map's own effect resolves from. A
    /// `prefersClearTopEdge()` or a `.soft` here would be a different look.
    @Test func theTopEdgeEffectIsTheSystemDefault() {
        let blur = StatusBarBlurView()
        #expect(!blur.edgeScrollView.topEdgeEffect.isHidden)
        #expect(blur.edgeScrollView.topEdgeEffect.style == .automatic)
    }

    /// The effect only shows over content scrolled under the edge, so the
    /// empty content sits one screen past its top.
    @Test func theScrollViewIsScrolledPastItsTop() {
        let blur = StatusBarBlurView()
        blur.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        blur.layoutIfNeeded()
        let scroll = blur.edgeScrollView
        #expect(scroll.contentOffset == CGPoint(x: 0, y: 874))
        #expect(scroll.contentSize == CGSize(width: 402, height: 874 * 3))
    }

    // MARK: Geometry

    @Test func aWindowTopGetsTheWholeBand() {
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 62, hostTopInWindow: 0) == 62)
    }

    @Test func aHostBelowTheBandGetsNothing() {
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 62, hostTopInWindow: 400) == 0)
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 62, hostTopInWindow: 62) == 0)
    }

    @Test func aHostStraddlingTheBandGetsItsOverlap() {
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 62, hostTopInWindow: 20) == 42)
    }

    /// Landscape: no status bar, no inset, no blur.
    @Test func noStatusBarMeansNoBand() {
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 0, hostTopInWindow: 0) == 0)
    }

    @Test func aHostAboveTheWindowTopNeverGetsMoreThanTheBand() {
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 62, hostTopInWindow: -30) == 62)
    }

    /// Off-window there is no band to cover, so the view stays hidden.
    @Test func offWindowItIsHidden() {
        let blur = StatusBarBlurView()
        blur.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        blur.layoutIfNeeded()
        #expect(blur.isHidden)
    }

    // MARK: Helpers

    /// Whether every other window subview is drawn under `band`: Core
    /// Animation draws siblings in `zPosition` order, then in subview order.
    private static func drawsOverEverySibling(_ band: UIView, in window: UIWindow) -> Bool {
        window.subviews.allSatisfy { sibling in
            sibling === band || sibling.layer.zPosition < band.layer.zPosition
        }
    }

    private static func containsBand(_ view: UIView) -> Bool {
        view is StatusBarBlurView || view.subviews.contains(where: containsBand)
    }
}
