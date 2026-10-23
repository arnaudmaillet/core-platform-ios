import CoreGraphics
import DesignSystem
import Testing
@testable import HeroPage

/// The hero page's scroll arithmetic (#1652): the profile's numbers, moved
/// out of its controller unchanged.
struct HeroScrollCoordinatorTests {
    /// A profile-shaped header: 640 pt tall under a 116 pt bar, with a 60 pt
    /// selector slot kept when docked.
    private let coordinator = HeroScrollCoordinator(headerHeight: 640, safeTop: 116, dockedSlot: 60)

    @Test func theDockLineLeavesTheSlotAndTheContentFloorDoesNot() {
        #expect(coordinator.dockLine == 464)
        #expect(coordinator.contentFloor == 524)
    }

    @Test func aHeaderShorterThanTheBarNeverTravels() {
        let short = HeroScrollCoordinator(headerHeight: 100, safeTop: 116, dockedSlot: 60)
        #expect(short.dockLine == 0)
        #expect(short.contentFloor == 0)
        #expect(short.detents() == [0])
    }

    /// The header follows the content to the dock line and stops; a pull
    /// past the top carries it down by the overscroll.
    @Test func theHeaderFollowsUpToTheDockLineAndStretchesBelowTheTop() {
        #expect(coordinator.headerTop(travelled: 0) == 0)
        #expect(coordinator.headerTop(travelled: 200) == -200)
        #expect(coordinator.headerTop(travelled: 900) == -464)
        #expect(coordinator.headerTop(travelled: -40) == 40)
    }

    /// The identity is whole until 90 pt before the dock line, gone at it.
    @Test func theIdentityFadesOutOverTheLastStretchBeforeTheDockLine() {
        #expect(coordinator.identityAlpha(travelled: 0) == 1)
        #expect(coordinator.identityAlpha(travelled: 464 - HeaderIdentityFade.distance) == 1)
        #expect(abs(coordinator.identityAlpha(travelled: 464 - HeaderIdentityFade.distance / 2) - 0.5) < 0.001)
        #expect(coordinator.identityAlpha(travelled: 464) == 0)
        #expect(coordinator.identityAlpha(travelled: 900) == 0)
    }

    @Test func theBarIsAtRestOnlyAtTheTop() {
        #expect(coordinator.barIsAtRest(travelled: 0))
        #expect(coordinator.barIsAtRest(travelled: -30))
        #expect(!coordinator.barIsAtRest(travelled: 1))
    }

    /// A foot goes under the bar once the header has carried it there; at
    /// rest, or with no laid-out foot, nothing is.
    @Test func anElementIsUnderTheBarOnlyOnceTheHeaderHasCarriedItThere() {
        // A tray whose foot is 400 pt down: under the 116 pt bar after 284.
        #expect(!coordinator.isUnderBar(foot: 400, travelled: 283))
        #expect(coordinator.isUnderBar(foot: 400, travelled: 284))
        #expect(!coordinator.isUnderBar(foot: 0, travelled: 300), "a foot not laid out yet")
        #expect(!coordinator.isUnderBar(foot: 100, travelled: 0), "at rest nothing is under the bar")
    }

    /// The profile's detents (`ProfileScrollDetents`, before #1652): top,
    /// the band avatar's notch, the first post — a notch past it is none.
    @Test func theDetentsAreTheTopTheNotchAndTheFirstRow() {
        let profile = HeroScrollCoordinator(headerHeight: 716, safeTop: 116, dockedSlot: 60)
        #expect(profile.detents(notch: 188) == [0, 188, 600])
        #expect(profile.detents() == [0, 600])
        #expect(profile.detents(notch: 700) == [0, 600])
        #expect(profile.detents(notch: 0) == [0, 600])
    }
}
