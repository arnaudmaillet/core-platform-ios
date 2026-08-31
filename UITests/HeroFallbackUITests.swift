import XCTest

/// The degradations, exercised end-to-end (plan IDs S04, S08, S10–S12, D11):
/// every way a post opens when there is nothing to fly, or the thing to fly
/// is late, failing, or gone — each must land somewhere sane and leave the
/// same nothing behind as the happy path.
final class HeroFallbackUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - S04/S08: the reveal family, via the Maps text pin

    /// A text pin opens as a REVEAL (the marker's disc is the window) — the
    /// scripted opener drives it, the swipe closes it, and the checklist is
    /// the same one the hero owes. This is the fallback-presentation family's
    /// end-to-end: no card, no flight, still zero residue.
    func testATextPinRevealOpensAndClosesClean() {
        let app = launchHeroApp(arguments: ["-maps-open-first-text-pin"])
        let opened = waitForHeroSettle(in: app, after: 0, "the text-pin reveal never settled")
        assertHeroResidueClear(opened, "after the reveal opened")
        attachHeroEvidence(app, name: "s04-text-reveal-open")

        let before = opened?.sequence ?? 0
        app.swipeRight()
        let returned = waitForHeroSettle(in: app, after: before, "the reveal close never settled")
        assertHeroResidueClear(returned, "after the reveal closed")
        attachHeroEvidence(app, name: "s04-text-reveal-closed")
    }

    /// The media pin flies a PinCardView — the Maps side of the shared
    /// machinery, smoke-tested through the same checklist.
    func testAMediaPinFliesAndReturns() {
        let app = launchHeroApp(arguments: ["-maps-open-first-pin", "-maps-force-video"])
        let opened = waitForHeroSettle(in: app, after: 0, "the pin flight never settled")
        assertHeroResidueClear(opened, "after the pin opened")
        attachHeroEvidence(app, name: "s08-pin-open")

        let before = opened?.sequence ?? 0
        app.navigationBars.buttons.firstMatch.tap()
        let returned = waitForHeroSettle(in: app, after: before, "the pin return never settled")
        assertHeroResidueClear(returned, "after the pin return")
        attachHeroEvidence(app, name: "s08-pin-returned")
    }

    // MARK: - S10: the cold open — poster flight, mid-air adoption, slow world

    /// Injected latency makes every hydration late: the card takes off with a
    /// poster, the retry asks all flight long, the reveal gate holds. All of
    /// that machinery must still resolve to a clean settle — and crucially,
    /// the retry link itself must be gone (`retries=0`), because its deadline
    /// is the one thing that stops it.
    func testAColdOpenUnderLatencySettlesClean() {
        let app = launchHeroApp(arguments: [
            "-select-tab", "1", "-mock-latency", "700",
        ])
        waitForHeroSettle(in: app, after: 0)
        let tile = app.collectionViews.firstMatch.cells.firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "no tile under latency")
        let baseline = heroProbe(in: app)?.sequence ?? 0
        tile.tap()
        let opened = waitForHeroSettle(in: app, after: baseline, timeout: 30,
                                       "the cold open never settled")
        assertHeroResidueClear(opened, "after a cold open under latency")
        attachHeroEvidence(app, name: "s10-cold-open")

        let before = opened?.sequence ?? 0
        app.swipeRight()
        assertHeroResidueClear(
            waitForHeroSettle(in: app, after: before, timeout: 30),
            "after returning from a cold open"
        )
    }

    // MARK: - S11: a failing backend behind the page

    /// Comments and engagement failing does not touch the flight: the page
    /// opens on the projection, the ticker stays quiet, and the whole round
    /// trip leaves nothing behind. The robustness claim is "a broken backend
    /// cannot strand a transition".
    func testABrokenBackendBehindThePageStillClosesClean() {
        let app = launchHeroApp(arguments: [
            "-select-tab", "1", "-mock-fail", "comment", "-mock-fail-rate", "1",
        ])
        waitForHeroSettle(in: app, after: 0)
        let tile = app.collectionViews.firstMatch.cells.firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        let baseline = heroProbe(in: app)?.sequence ?? 0
        tile.tap()
        let opened = waitForHeroSettle(in: app, after: baseline,
                                       "the open never settled with comments failing")
        assertHeroResidueClear(opened, "after opening over a failing backend")
        attachHeroEvidence(app, name: "s11-broken-backend-open")

        let before = opened?.sequence ?? 0
        app.navigationBars.buttons.firstMatch.tap()
        assertHeroResidueClear(
            waitForHeroSettle(in: app, after: before),
            "after returning over a failing backend"
        )
    }

    // MARK: - D11: the vertical veto — comments own their territory

    /// With the comments open, a downward swipe belongs to the thread, not to
    /// the dismissal: the page must STAY. Closing them hands the axis back.
    /// (`-foryou-open-comments` opens the first post with its thread
    /// presented, which is also the masked-reveal opening — S06 rides along.)
    func testAnOpenThreadVetoesTheVerticalDismissal() {
        let app = launchHeroApp(arguments: [
            "-select-tab", "1", "-foryou-open-comments", "0",
        ])
        let opened = waitForHeroSettle(in: app, after: 0, timeout: 30,
                                       "the comments open never settled")
        attachHeroEvidence(app, name: "d11-comments-open")

        // The veto: swipe down mid-screen. If the grab claimed this, the page
        // would leave and the grid would come back — so "still not on the
        // grid" is the assertion, checked after the audit sampled again.
        let before = opened?.sequence ?? 0
        app.swipeDown()
        let after = waitForHeroSettle(in: app, after: before)
        XCTAssertTrue(app.navigationBars.firstMatch.exists,
                      "the vertical grab dismissed through an open thread")
        assertHeroResidueClear(after, "after the vetoed swipe")
        attachHeroEvidence(app, name: "d11-veto-held")
    }
}
