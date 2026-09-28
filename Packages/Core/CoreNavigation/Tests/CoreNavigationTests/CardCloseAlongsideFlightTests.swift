@testable import CoreNavigation
import Testing
import UIKit

/// The shared arming of a card-shaped close beside a hero flight.
///
/// Three hosts wrote this by hand — For You's grid, the place page's tiles —
/// and the third, a profile, never got it: a text page reached by paging from
/// a media post then had no drag and a chevron that cut. One implementation
/// now, and these pin its rules, because each rule is a defect that shipped
/// once already (see `DismissalDriverArbitrationTests`).
@MainActor
struct CardCloseAlongsideFlightTests {
    private final class StubFeed: UIViewController, ZoomTransitionDestination {
        var kind: ZoomDismissalKind = .hero

        var zoomDismissalKind: ZoomDismissalKind { kind }
        var isReadyForInteractiveDismissal: Bool { true }
        func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
        func zoomFlightChrome() -> UIView? { nil }
        func setZoomContentHidden(_ hidden: Bool) {}
        func zoomTransitionDidEnd() {}
        func setContentScrollEnabled(_ enabled: Bool) {}
    }

    private func armed(
        kind: ZoomDismissalKind, staged: @escaping () -> Bool = { true }
    ) -> (InteractiveSlideDismissal, StubFeed, () -> Int) {
        let feed = StubFeed()
        feed.kind = kind
        let driver = InteractiveSlideDismissal()
        var stages = 0
        driver.armAsCardCloseAlongsideFlight(on: feed) { _ in
            stages += 1
            return staged()
        }
        return (driver, feed, { stages })
    }

    /// Arbitrated against the hero grab — otherwise both drivers claim a media
    /// page's drag, or (with the gate the other way round) neither claims a
    /// text page's.
    @Test func itArbitratesWithTheHeroGrab() {
        let (driver, feed, _) = armed(kind: .card)
        #expect(driver.arbitratesWithHeroGrab)
        #expect(driver.prepareForDismissal != nil)
        let pans = feed.view.gestureRecognizers?.filter { $0 is UIPanGestureRecognizer } ?? []
        #expect(pans.count == 1, "the close attached no drag of its own")
    }

    /// ⚠️ NEVER FOR A HERO'S POP. This hook is asked for every pop, and
    /// staging a card close conceals the landing a flight is about to land on.
    @Test func aPostThatFliesIsNeverStaged() {
        let (driver, feed, stages) = armed(kind: .hero)
        driver.prepareForDismissal?(.vertical)
        driver.prepareForDismissal?(.horizontal)
        #expect(stages() == 0)
        withExtendedLifetime(feed) {}
    }

    /// ⚠️ ONCE. A swipe asks twice — the grab, then the pop's animator — and a
    /// staging that moves a card undoes itself the second time.
    @Test func aCardCloseIsStagedOnce() {
        let (driver, feed, stages) = armed(kind: .card)
        driver.prepareForDismissal?(.vertical)
        driver.prepareForDismissal?(.vertical)
        #expect(stages() == 1)
        withExtendedLifetime(feed) {}
    }

    /// The kind is asked AT THE CLOSE, not at arming: the feed is a pager, and
    /// the post that opened it (a media one, which is why a flight opened it)
    /// is not the post being closed.
    @Test func theKindIsAskedAtTheCloseNotAtTheTap() {
        let (driver, feed, stages) = armed(kind: .hero)
        driver.prepareForDismissal?(.vertical)
        #expect(stages() == 0)
        feed.kind = .card
        driver.prepareForDismissal?(.vertical)
        #expect(stages() == 1)
    }

    /// A host that could not answer yet leaves the latch open for the next ask.
    @Test func aStagingThatDeclinedMayBeAskedAgain() {
        var answer = false
        let (driver, feed, stages) = armed(kind: .card, staged: { answer })
        driver.prepareForDismissal?(.vertical)
        answer = true
        driver.prepareForDismissal?(.vertical)
        driver.prepareForDismissal?(.vertical)
        #expect(stages() == 2)
        withExtendedLifetime(feed) {}
    }

    /// The feed is held WEAKLY — the driver lives on the feed's own view (its
    /// pan), so a strong capture would be a cycle. A feed that is gone stages
    /// nothing rather than crashing or staging for a screen nobody sees.
    @Test func aFeedThatIsGoneStagesNothing() {
        var stages = 0
        let driver = InteractiveSlideDismissal()
        do {
            let feed = StubFeed()
            feed.kind = .card
            driver.armAsCardCloseAlongsideFlight(on: feed) { _ in stages += 1; return true }
        }
        driver.prepareForDismissal?(.vertical)
        #expect(stages == 0)
    }

    /// Nothing from the last opening survives into this one: arming clears a
    /// landing opinion and a geometry left by the previous presentation.
    @Test func armingForgetsThePreviousPresentation() {
        let feed = StubFeed()
        let driver = InteractiveSlideDismissal()
        driver.heroLandingAcceptsHero = { false }
        driver.heroClaimsAxis = { _ in false }
        driver.revealPresents = true
        driver.armAsCardCloseAlongsideFlight(on: feed) { _ in true }
        #expect(driver.heroLandingAcceptsHero == nil)
        #expect(driver.heroClaimsAxis == nil)
        #expect(driver.revealPresents == false)
        #expect(driver.revealGeometry == nil)
    }

    // MARK: - The axis-aware form (the map's)

    /// ⚠️ AN AXIS TAKEN FROM THE HERO IS STAGED FOR A PHOTOGRAPH TOO — and the
    /// other axis still is not.
    ///
    /// Downward onto a place page, every post closes as the card onto its
    /// Activity row; a media post's close was gated out here by its kind, so
    /// the window had no geometry and the page came back on a plain slide.
    @Test func anAxisTakenFromTheHeroIsStagedForAMediaPost() {
        let feed = StubFeed()
        feed.kind = .hero
        let driver = InteractiveSlideDismissal()
        var axes: [ZoomDismissAxis] = []
        driver.armAsCardCloseAlongsideFlight(on: feed, restagesOnEveryAttempt: true) { _, axis in
            axes.append(axis)
            return true
        }
        driver.heroClaimsAxis = { $0 != .vertical }
        driver.prepareForDismissal?(.horizontal)
        driver.prepareForDismissal?(.vertical)
        #expect(axes == [.vertical], "the flight's axis was staged, or the card's was not")
        withExtendedLifetime(feed) {}
    }

    /// The axis reaches the host: the map's two axes land on two different
    /// screens, and a staging that cannot tell them apart aims one at the other.
    @Test func theAxisIsHandedToTheStaging() {
        let feed = StubFeed()
        feed.kind = .card
        let driver = InteractiveSlideDismissal()
        var axes: [ZoomDismissAxis] = []
        driver.armAsCardCloseAlongsideFlight(on: feed, restagesOnEveryAttempt: true) { _, axis in
            axes.append(axis)
            return true
        }
        driver.prepareForDismissal?(.vertical)
        driver.prepareForDismissal?(.horizontal)
        #expect(axes == [.vertical, .horizontal])
        withExtendedLifetime(feed) {}
    }

    /// ⚠️ NO LATCH when restaging: an abandoned vertical close must not leave
    /// its landing armed for the chevron that follows. A staging that answered
    /// `true` is asked again all the same.
    @Test func aRestagingHostIsAskedOnEveryAttempt() {
        let feed = StubFeed()
        feed.kind = .card
        let driver = InteractiveSlideDismissal()
        var stages = 0
        driver.armAsCardCloseAlongsideFlight(on: feed, restagesOnEveryAttempt: true) { _, _ in
            stages += 1
            return true
        }
        driver.prepareForDismissal?(.vertical)
        driver.prepareForDismissal?(.vertical)
        driver.prepareForDismissal?(.horizontal)
        #expect(stages == 3)
        withExtendedLifetime(feed) {}
    }

    /// Restaging relaxes the latch and nothing else: a post that flies is
    /// still never staged, and the shared arming rules still hold.
    @Test func aRestagingHostStillNeverStagesAFlight() {
        let feed = StubFeed()
        feed.kind = .hero
        let driver = InteractiveSlideDismissal()
        var stages = 0
        driver.armAsCardCloseAlongsideFlight(on: feed, restagesOnEveryAttempt: true) { _, _ in
            stages += 1
            return true
        }
        driver.prepareForDismissal?(.horizontal)
        #expect(stages == 0)
        #expect(driver.arbitratesWithHeroGrab)
        #expect(driver.debugArmedAxes == [.horizontal, .vertical])
        withExtendedLifetime(feed) {}
    }

    /// With the latch ON, the axis-aware form is the one-closure form: once.
    @Test func theLatchedAxisAwareFormStagesOnce() {
        let feed = StubFeed()
        feed.kind = .card
        let driver = InteractiveSlideDismissal()
        var stages = 0
        driver.armAsCardCloseAlongsideFlight(on: feed, restagesOnEveryAttempt: false) { _, _ in
            stages += 1
            return true
        }
        driver.prepareForDismissal?(.vertical)
        driver.prepareForDismissal?(.horizontal)
        #expect(stages == 1)
        withExtendedLifetime(feed) {}
    }
}
