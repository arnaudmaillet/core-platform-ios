import CoreGraphics
import DesignSystem
import Testing
import UIKit
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

    /// A line's passage under the bar (#2334): 0 until its top reaches the
    /// bar's foot, 1 once its foot has passed it, in proportion between —
    /// what the profile's bar @handle follows.
    @Test func aLinesPassageUnderTheBarIsAFunctionOfThePosition() {
        // A handle line from 300 to 320 pt: its top at the 116 pt bar's foot
        // after 184, its foot after 204.
        #expect(coordinator.passage(top: 300, foot: 320, travelled: 150) == 0)
        #expect(coordinator.passage(top: 300, foot: 320, travelled: 184) == 0)
        #expect(abs(coordinator.passage(top: 300, foot: 320, travelled: 189) - 0.25) < 0.001)
        #expect(abs(coordinator.passage(top: 300, foot: 320, travelled: 194) - 0.5) < 0.001)
        #expect(coordinator.passage(top: 300, foot: 320, travelled: 204) == 1)
        #expect(coordinator.passage(top: 300, foot: 320, travelled: 400) == 1)
        // Monotonic, both ways: the way down is the way up reversed.
        let passages = stride(from: 150, through: 260, by: 2).map {
            coordinator.passage(top: 300, foot: 320, travelled: CGFloat($0))
        }
        #expect(passages == passages.sorted(), "the passage went back on the way up")
    }

    /// At rest, on a pull, or for a line not laid out yet, nothing has passed.
    @Test func atRestNoLineHasPassed() {
        #expect(coordinator.passage(top: 50, foot: 70, travelled: 0) == 0, "at rest")
        #expect(coordinator.passage(top: 50, foot: 70, travelled: -40) == 0, "on a pull")
        #expect(coordinator.passage(top: 0, foot: 0, travelled: 300) == 0, "a line not laid out yet")
    }

    /// The header stops at its dock line, and so does a line's passage: a
    /// line still below the bar there never passes.
    @Test func aLineBelowTheDockedHeaderNeverPasses() {
        // Docked after 464: a line from 600 to 620 stands at 136…156.
        #expect(coordinator.passage(top: 600, foot: 620, travelled: 2_000) == 0)
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

/// The bar's title on its way in (#2334): native, faded and climbing by the
/// handle line's passage, on steps — and no attributed title once whole.
struct HeroBarTitleTests {
    @Test func thePassageIsSteppedAndClamped() {
        #expect(HeroBarTitle.step(-1) == 0)
        #expect(HeroBarTitle.step(0.02) == 0)
        #expect(HeroBarTitle.step(0.5) == 0.5)
        #expect(HeroBarTitle.step(0.51) == 0.5)
        #expect(HeroBarTitle.step(0.98) == 1)
        #expect(HeroBarTitle.step(3) == 1)
        let steps = Set(stride(from: 0.0, through: 1.0, by: 0.001).map { HeroBarTitle.step(CGFloat($0)) })
        #expect(steps.count == Int(HeroBarTitle.steps) + 1, "\(steps.count) steps")
    }

    /// Untitled and whole, no attributed title: the bar's own title, in the
    /// bar's own dress.
    @Test func noAttributedTitleOutsideTheArrival() {
        #expect(HeroBarTitle.attributed("@kenji.dev", opacity: 0, ink: .label, reduceMotion: false) == nil)
        #expect(HeroBarTitle.attributed("@kenji.dev", opacity: 1, ink: .label, reduceMotion: false) == nil)
    }

    /// Half way: the bar's ink at half its alpha, the title half its rise
    /// below its place.
    @Test func halfWayTheTitleIsHalfFadedAndHalfRisen() throws {
        let title = try #require(HeroBarTitle.attributed("@kenji.dev", opacity: 0.5, ink: .white, reduceMotion: false))
        #expect(String(title.characters) == "@kenji.dev")
        let ink = try #require(title.uiKit.foregroundColor)
        var alpha: CGFloat = 0
        ink.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        #expect(abs(alpha - 0.5) < 0.01, "alpha \(alpha)")
        let offset = try #require(title.uiKit.baselineOffset)
        #expect(abs(offset + HeroBarTitle.rise / 2) < 0.01, "offset \(offset)")
        // Lower at the start than near the end: it climbs as it comes in.
        let early = try #require(HeroBarTitle.attributed("@a", opacity: 0.1, ink: .label, reduceMotion: false)?.uiKit.baselineOffset)
        let late = try #require(HeroBarTitle.attributed("@a", opacity: 0.9, ink: .label, reduceMotion: false)?.uiKit.baselineOffset)
        #expect(early < late)
    }

    /// Reduce Motion: a plain fade, no climb.
    @Test func underReduceMotionItOnlyFades() throws {
        let title = try #require(HeroBarTitle.attributed("@kenji.dev", opacity: 0.3, ink: .label, reduceMotion: true))
        #expect((title.uiKit.baselineOffset ?? 0) == 0)
        #expect(title.uiKit.foregroundColor != nil)
    }
}
