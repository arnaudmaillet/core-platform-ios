import Testing
import UIKit
@testable import DesignSystem

/// `StatusBarBlurView`: always installed, the inert scroll view that owns the
/// blur, and the band geometry. The look itself — the Map's edge effect, filter
/// for filter — was established on simulator dumps; these pin the rules it
/// rests on. No test attaches the view to a window.
@MainActor
struct StatusBarBlurViewTests {

    // MARK: Install

    /// No launch argument any more: installing always adds the blur.
    @Test func installingAddsTheBlur() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let blur = StatusBarBlurView.install(in: host)
        #expect(blur.superview === host)
    }

    @Test func installingTwiceKeepsOneBlur() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let first = StatusBarBlurView.install(in: host)
        let second = StatusBarBlurView.install(in: host)
        #expect(first === second)
        #expect(host.subviews.filter { $0 is StatusBarBlurView }.count == 1)
    }

    /// Above the host's content whatever is added later, and never in the way
    /// of a touch.
    @Test func itSitsAboveContentAndTakesNoTouches() {
        let host = UIView()
        let blur = StatusBarBlurView.install(in: host)
        host.addSubview(UIView())
        #expect(blur.layer.zPosition > 0)
        #expect(!blur.isUserInteractionEnabled)
    }

    /// It covers the whole host, so its scroll view gets the same safe area a
    /// real list there would — what UIKit sizes the effect from.
    @Test func itCoversTheWholeHost() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let blur = StatusBarBlurView.install(in: host)
        host.layoutIfNeeded()
        #expect(blur.frame == host.bounds)
        #expect(blur.edgeScrollView.frame == blur.bounds)
    }

    // MARK: The inert scroll view

    /// ⚠️ Two on-screen scroll views answering the status-bar tap means NEITHER
    /// scrolls: the screen's real list would lose tap-to-top.
    @Test func theScrollViewNeverAnswersTheStatusBarTap() {
        let blur = StatusBarBlurView.install(in: UIView())
        #expect(!blur.edgeScrollView.scrollsToTop)
    }

    @Test func theScrollViewNeverScrollsNorTakesTouches() {
        let blur = StatusBarBlurView.install(in: UIView())
        #expect(!blur.edgeScrollView.isScrollEnabled)
        #expect(!blur.edgeScrollView.isUserInteractionEnabled)
    }

    /// VoiceOver never lands on it — not the blur, not its scroll view.
    @Test func itIsInvisibleToAccessibility() {
        let blur = StatusBarBlurView.install(in: UIView())
        #expect(blur.accessibilityElementsHidden)
        #expect(blur.edgeScrollView.accessibilityElementsHidden)
        #expect(!blur.edgeScrollView.isAccessibilityElement)
    }

    /// The blur IS the top edge effect left as UIKit makes it — `.automatic`,
    /// shown — the style the Map's own effect resolves from. A
    /// `prefersClearTopEdge()` or a `.soft` here would be a different look.
    @Test func theTopEdgeEffectIsTheSystemDefault() {
        let blur = StatusBarBlurView.install(in: UIView())
        #expect(!blur.edgeScrollView.topEdgeEffect.isHidden)
        #expect(blur.edgeScrollView.topEdgeEffect.style == .automatic)
    }

    /// The effect only shows over content scrolled under the edge, so the
    /// empty content sits one screen past its top.
    @Test func theScrollViewIsScrolledPastItsTop() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let blur = StatusBarBlurView.install(in: host)
        host.layoutIfNeeded()
        blur.layoutIfNeeded()
        let scroll = blur.edgeScrollView
        #expect(scroll.contentOffset == CGPoint(x: 0, y: 874))
        #expect(scroll.contentSize == CGSize(width: 402, height: 874 * 3))
    }

    // MARK: Geometry

    @Test func aHostAtTheWindowTopGetsTheWholeBand() {
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

    /// Off-window there is no band, so the view stays hidden.
    @Test func offWindowItIsHidden() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let blur = StatusBarBlurView.install(in: host)
        host.layoutIfNeeded()
        blur.layoutIfNeeded()
        #expect(blur.isHidden)
    }
}
