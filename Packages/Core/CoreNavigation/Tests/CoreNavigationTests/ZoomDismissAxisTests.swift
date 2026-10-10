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

    // MARK: - Upward, past a finished source (#628)

    /// Upward matches only when armed, and only outbound-upward and
    /// predominantly vertical — the same rule as the other two.
    @Test func upwardMatchesOnlyWhenArmed() {
        let up = CGPoint(x: 40, y: -300)
        #expect(ZoomDismissAxis.match(velocity: up, axes: [.horizontal, .vertical]) == nil,
                "unarmed, upward is the pager's next post")
        #expect(ZoomDismissAxis.match(velocity: up, axes: [.upward]) == .upward)
        #expect(ZoomDismissAxis.match(velocity: CGPoint(x: 40, y: 300), axes: [.upward]) == nil, "downward")
        #expect(ZoomDismissAxis.match(velocity: CGPoint(x: 300, y: -250), axes: [.upward]) == nil,
                "mostly sideways")
    }

    /// The drivers arm upward wherever vertical is, and nowhere else: a
    /// horizontal-only driver (a profile's tab pager) never gains it.
    @Test func upwardRidesWithVertical() {
        #expect(ZoomDismissAxis.withUpward([.horizontal, .vertical]) == [.horizontal, .vertical, .upward])
        #expect(ZoomDismissAxis.withUpward([.vertical]) == [.vertical, .upward])
        #expect(ZoomDismissAxis.withUpward([.horizontal]) == [.horizontal])
    }

    /// Travel is positive outbound on every axis, so progress and the release
    /// velocity read the same whichever way the hand went.
    @Test func upwardTravelIsPositiveGoingUp() {
        let size = CGSize(width: 402, height: 874)
        #expect(ZoomDismissAxis.upward.along(CGPoint(x: 10, y: -200)) == 200)
        #expect(ZoomDismissAxis.upward.across(CGPoint(x: 10, y: -200)) == 10)
        #expect(ZoomDismissAxis.upward.span(of: size) == 874)
        #expect(ZoomDismissAxis.upward.offset(along: 200, across: 10) == CGPoint(x: 10, y: -200),
                "the window follows the finger up")
    }

    /// ⚠️ A SWIPE UP LANDS WHERE A SWIPE RIGHT DOES (#761, reversing #685):
    /// on the source — a place feed's end closes to the map; only a swipe
    /// down lands beneath, on the place page.
    @Test func upwardLandsWhereRightwardDoes() {
        #expect(ZoomDismissAxis.vertical.landsBeneath)
        #expect(!ZoomDismissAxis.upward.landsBeneath)
        #expect(!ZoomDismissAxis.horizontal.landsBeneath)
    }

    /// A driver armed with `upward` explicitly (the map marker's, #761)
    /// begins along it without `vertical`; `withUpward` adds nothing to it.
    @Test func upwardMayBeArmedWithoutVertical() {
        #expect(ZoomDismissAxis.withUpward([.horizontal, .upward]) == [.horizontal, .upward])
        #expect(ZoomDismissAxis.match(velocity: CGPoint(x: 10, y: -400), axes: [.horizontal, .upward]) == .upward)
        #expect(ZoomDismissAxis.match(velocity: CGPoint(x: 10, y: -400), axes: [.vertical]) == nil,
                "a driver left without upward claims no upward drag")
    }
}
