import CoreGraphics
import Testing
@testable import Feed

/// **The hand-driven page swipe, both ways (#2056, #2058).** The composer's
/// pan and the header band's page a text page or an engaged media page;
/// since the owner's call (2026-11-02) a downward drive steps to the
/// previous post, never past the first.
struct SnapPageDriveTests {
    private let page: CGFloat = 800

    @Test func aDecisiveUpwardDriveAdvances() {
        #expect(SnapPageDrive.step(translation: -200, velocity: 0, page: page) == 1)
        #expect(SnapPageDrive.step(translation: -40, velocity: -600, page: page) == 1)
    }

    /// Forward-only answered 0 here (#114): now the previous post.
    @Test func aDecisiveDownwardDrivePagesBack() {
        #expect(SnapPageDrive.step(translation: 200, velocity: 0, page: page) == -1)
        #expect(SnapPageDrive.step(translation: 40, velocity: 600, page: page) == -1)
    }

    @Test func anIndecisiveDriveSettlesHome() {
        #expect(SnapPageDrive.step(translation: -40, velocity: -100, page: page) == 0)
        #expect(SnapPageDrive.step(translation: 40, velocity: 100, page: page) == 0)
    }

    /// The finger turned back: a drag up flung down settles HOME, and a drag
    /// down flung up too — never a page the other way.
    @Test func aReversedDriveSettlesHome() {
        #expect(SnapPageDrive.step(translation: -150, velocity: 800, page: page) == 0)
        #expect(SnapPageDrive.step(translation: 150, velocity: -800, page: page) == 0)
    }

    /// A fling from rest: its velocity says which way.
    @Test func aFlingFromRestFollowsItsVelocity() {
        #expect(SnapPageDrive.step(translation: 0, velocity: -900, page: page) == 1)
        #expect(SnapPageDrive.step(translation: 0, velocity: 900, page: page) == -1)
    }

    /// The previous post at most, never past the first.
    @Test func theFloorIsThePreviousPostNeverPastTheFirst() {
        #expect(SnapPageDrive.floorIndex(origin: 3) == 2)
        #expect(SnapPageDrive.floorIndex(origin: 0) == 0)
        #expect(SnapPageDrive.target(origin: 0, step: -1, ceiling: 5) == 0, "the first post paged back")
        #expect(SnapPageDrive.target(origin: 3, step: -1, ceiling: 5) == 2)
        #expect(SnapPageDrive.target(origin: 3, step: 1, ceiling: 5) == 4)
        #expect(SnapPageDrive.target(origin: 5, step: 1, ceiling: 5) == 5, "past the last post")
    }
}
