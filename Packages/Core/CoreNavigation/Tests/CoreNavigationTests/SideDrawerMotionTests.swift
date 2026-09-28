import CoreGraphics
import Testing
@testable import CoreNavigation

/// The side drawer's arithmetic: width, finger tracking, rubber band, and the
/// release decision.
struct SideDrawerMotionTests {
    private let width: CGFloat = 338

    @Test func theDrawerLeavesASliverAndIsCappedOnWideScreens() {
        // An iPhone 18 Pro in portrait: 402 wide → 338 drawer, a 64pt sliver.
        #expect(SideDrawerMotion.drawerWidth(forContainerWidth: 402) == 338)
        #expect(SideDrawerMotion.drawerWidth(forContainerWidth: 375) == 315)
        // Landscape or a large canvas stops at the cap.
        #expect(SideDrawerMotion.drawerWidth(forContainerWidth: 932) == SideDrawerMotion.maximumWidth)
        #expect(SideDrawerMotion.drawerWidth(forContainerWidth: 0) == 0)
    }

    @Test func progressTracksTheFingerOneToOne() {
        #expect(SideDrawerMotion.progress(startProgress: 0, translation: width / 2, drawerWidth: width) == 0.5)
        #expect(SideDrawerMotion.progress(startProgress: 1, translation: -width / 4, drawerWidth: width) == 0.75)
    }

    @Test func progressStopsDeadAtClosed() {
        #expect(SideDrawerMotion.progress(startProgress: 0, translation: -120, drawerWidth: width) == 0)
        #expect(SideDrawerMotion.progress(startProgress: 1, translation: -width * 3, drawerWidth: width) == 0)
    }

    /// Past fully open the main screen keeps moving, with resistance, and
    /// never beyond the limit — however far the finger goes.
    @Test func pastOpenTheRubberBandStretchesAndSaturates() {
        let slight = SideDrawerMotion.progress(startProgress: 1, translation: 20, drawerWidth: width)
        let far = SideDrawerMotion.progress(startProgress: 1, translation: 400, drawerWidth: width)
        let absurd = SideDrawerMotion.progress(startProgress: 1, translation: 40_000, drawerWidth: width)
        #expect(slight > 1)
        #expect(slight < 1 + 20 / width) // resisted: less than the finger moved
        #expect(far > slight)
        #expect(absurd < 1 + SideDrawerMotion.overshootLimit)
    }

    /// The band starts at the finger's own slope, so there is no kink at 1.
    @Test func theRubberBandIsContinuousAtOpen() {
        let justPast = SideDrawerMotion.rubberBanded(1.0001)
        #expect(abs(justPast - 1.0001) < 0.0001)
        #expect(SideDrawerMotion.rubberBanded(1) == 1)
    }

    @Test func aFlickDecidesByItsDirection() {
        #expect(SideDrawerMotion.shouldOpen(progress: 0.1, velocity: 800, drawerWidth: width))
        #expect(!SideDrawerMotion.shouldOpen(progress: 0.9, velocity: -800, drawerWidth: width))
    }

    @Test func aSlowReleaseSettlesTowardTheNearerEnd() {
        #expect(SideDrawerMotion.shouldOpen(progress: 0.6, velocity: 0, drawerWidth: width))
        #expect(!SideDrawerMotion.shouldOpen(progress: 0.4, velocity: 0, drawerWidth: width))
        // A slow drift carries the projection over the line.
        #expect(SideDrawerMotion.shouldOpen(progress: 0.4, velocity: 300, drawerWidth: width))
        #expect(!SideDrawerMotion.shouldOpen(progress: 0.6, velocity: -300, drawerWidth: width))
    }

    @Test func theSpringOnlyInheritsVelocityTowardItsTarget() {
        let toward = SideDrawerMotion.initialSpringVelocity(from: 0.5, to: 1, velocity: 338, drawerWidth: width)
        #expect(abs(toward - 2) < 0.001) // 338 pt/s over 169 pt remaining
        #expect(SideDrawerMotion.initialSpringVelocity(from: 0.5, to: 1, velocity: -338, drawerWidth: width) == 0)
        #expect(SideDrawerMotion.initialSpringVelocity(from: 1, to: 1, velocity: 900, drawerWidth: width) == 0)
    }
}
