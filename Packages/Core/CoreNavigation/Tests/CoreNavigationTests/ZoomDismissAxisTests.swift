import Testing
import CoreGraphics
@testable import CoreNavigation

/// The axis split for the grab-to-dismiss: which axis (if any) a hand
/// movement arms, and how the axis decomposes the drag's geometry. Pure
/// logic, extracted so the gesture rules are testable without a finger.
struct ZoomDismissAxisTests {
    private let both: Set<ZoomDismissAxis> = [.horizontal, .vertical]

    // MARK: - Matching

    @Test func aRightwardMovementMatchesHorizontal() {
        #expect(ZoomDismissAxis.match(velocity: CGPoint(x: 300, y: 50), axes: both) == .horizontal)
    }

    @Test func aDownwardMovementMatchesVertical() {
        #expect(ZoomDismissAxis.match(velocity: CGPoint(x: 50, y: 300), axes: both) == .vertical)
    }

    /// Inbound movements (leftward, upward) are never a dismissal — leftward
    /// means nothing and upward is the pager's next-post swipe.
    @Test func inboundMovementsMatchNothing() {
        #expect(ZoomDismissAxis.match(velocity: CGPoint(x: -300, y: 50), axes: both) == nil)
        #expect(ZoomDismissAxis.match(velocity: CGPoint(x: 50, y: -300), axes: both) == nil)
    }

    /// Each axis declines the other's movement when armed alone — the rule
    /// that lets Case B hang two different pops on two single-axis drivers.
    @Test func aSingleArmedAxisDeclinesTheOthersMovement() {
        #expect(ZoomDismissAxis.match(velocity: CGPoint(x: 50, y: 300), axes: [.horizontal]) == nil)
        #expect(ZoomDismissAxis.match(velocity: CGPoint(x: 300, y: 50), axes: [.vertical]) == nil)
    }

    /// A perfect diagonal favors neither axis: |vx| > |vy| and |vy| > |vx|
    /// are both false, so nothing begins and the next event decides. Refusing
    /// beats guessing — the gesture system re-asks continuously.
    @Test func aPerfectDiagonalMatchesNothing() {
        #expect(ZoomDismissAxis.match(velocity: CGPoint(x: 300, y: 300), axes: both) == nil)
    }

    @Test func aRestingHandMatchesNothing() {
        #expect(ZoomDismissAxis.match(velocity: .zero, axes: both) == nil)
    }

    // MARK: - Decomposition

    @Test func alongAndAcrossAreMirrors() {
        let point = CGPoint(x: 120, y: 45)
        #expect(ZoomDismissAxis.horizontal.along(point) == 120)
        #expect(ZoomDismissAxis.horizontal.across(point) == 45)
        #expect(ZoomDismissAxis.vertical.along(point) == 45)
        #expect(ZoomDismissAxis.vertical.across(point) == 120)
    }

    @Test func spanReadsTheTravelDimension() {
        let size = CGSize(width: 402, height: 874)
        #expect(ZoomDismissAxis.horizontal.span(of: size) == 402)
        #expect(ZoomDismissAxis.vertical.span(of: size) == 874)
    }

    /// offset(along:across:) must invert the along/across decomposition, so
    /// banding the two components separately and recomposing them cannot
    /// swap axes.
    @Test func offsetInvertsTheDecomposition() {
        let point = CGPoint(x: 120, y: 45)
        for axis in ZoomDismissAxis.allCases {
            let rebuilt = axis.offset(along: axis.along(point), across: axis.across(point))
            #expect(rebuilt == point)
        }
    }
}
