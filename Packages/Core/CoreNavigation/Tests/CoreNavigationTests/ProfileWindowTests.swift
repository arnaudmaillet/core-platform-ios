@testable import CoreNavigation
import Testing
import UIKit

/// The author's profile opened as a window (#1874, `-profile-window`): the
/// decision, and what the window driver is armed with.
@MainActor
struct ProfileWindowTests {
    private func geometry() -> RevealGeometry {
        RevealGeometry(sourceFrame: { _ in CGRect(x: 16, y: 800, width: 160, height: 48) }, sourceCornerRadius: 24)
    }

    /// Flag off: never. Reduce Motion: never. The Shots root: never.
    @Test func opensOnlyWithTheFlagWithMotionAndOffTheShotsRoot() {
        #expect(ProfileWindow.opens(flag: true, reducesMotion: false, isShotsRoot: false))
        #expect(!ProfileWindow.opens(flag: false, reducesMotion: false, isShotsRoot: false))
        #expect(!ProfileWindow.opens(flag: true, reducesMotion: true, isShotsRoot: false))
        #expect(!ProfileWindow.opens(flag: true, reducesMotion: false, isShotsRoot: true))
    }

    /// The test process never passes `-profile-window`: off.
    @Test func theFlagIsOffByDefault() {
        #expect(!ProfileWindow.isFlagOn)
        #expect(!ProfileWindow.opens(isShotsRoot: false))
    }

    /// Attached: the push is the reveal's, on the opening geometry, the
    /// fallback slides sideways, and the profile keeps its driver.
    @Test func attachingArmsTheWindowPush() {
        let profile = UIViewController()
        let slide = ProfileWindow.attach(to: profile, opening: geometry(), closing: { nil })
        #expect(slide.revealPresents)
        #expect(slide.revealGeometry != nil)
        #expect(slide.fallbackSlideAxis == .horizontal)
        #expect(slide.heroLandingAcceptsHero?() == false)
        #expect(ProfileWindow.driver(of: profile) === slide)
    }

    /// A screen nobody attached a window to has no driver: the plain push.
    @Test func anUnattachedProfileHasNoWindow() {
        #expect(ProfileWindow.driver(of: UIViewController()) == nil)
    }

    /// The close lands on what the source measures then; with nothing to
    /// land on, the plain slide — and the source the opening hid comes back.
    @Test func aCloseWithNoPillSlidesAndReleasesTheSource() {
        let profile = UIViewController()
        var landing: RevealGeometry? = geometry()
        var released = 0
        let slide = ProfileWindow.attach(
            to: profile, opening: geometry(), closing: { landing }, releaseSource: { released += 1 }
        )
        slide.prepareForDismissal?(.horizontal)
        #expect(slide.revealGeometry != nil)
        #expect(released == 0, "a window close gives the pill back at its landing, not before")
        landing = nil
        slide.prepareForDismissal?(.horizontal)
        #expect(slide.revealGeometry == nil)
        #expect(released == 1)
    }

    /// The driver does not keep the profile alive: popped and released, the
    /// profile goes, and its driver with it.
    @Test func theDriverDoesNotRetainTheProfile() {
        weak var weakProfile: UIViewController?
        weak var weakSlide: InteractiveSlideDismissal?
        do {
            let profile = UIViewController()
            weakProfile = profile
            weakSlide = ProfileWindow.attach(to: profile, opening: geometry(), closing: { nil })
        }
        #expect(weakProfile == nil)
        #expect(weakSlide == nil)
    }
}
