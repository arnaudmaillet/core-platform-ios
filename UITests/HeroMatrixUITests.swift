import XCTest

/// The hero matrix, driven by real fingers: open → full-screen → home again,
/// across the dismissal paths a viewer actually uses (plan IDs S01–S04,
/// D01–D06).
///
/// Two transition families share these screens, and the suite deliberately
/// exercises both. The REAL-TAP tests open whatever the feed's first card is
/// — on the mock corpus that is a TEXT card, so they drive the reveal/card
/// family end to end. The MEDIA HERO is then pinned by the hybrid tests
/// below: `-foryou-open 0` opens a guaranteed media post through the real
/// flight (the scripted opener polls for a COVER, which a text row never
/// gets), and the dismissal is a real finger.
///
/// Every case ends on the same checklist, read from the audit probe: no
/// animator, interruptor, retry link, flight card or stranded view survives
/// the settle, and no asset holds two players. The pixels ride along as
/// `.keepAlways` screenshots — the logs-green-over-a-broken-screen trap is
/// why evidence is captured even on a pass.
final class HeroMatrixUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchOnForYou(extra: [String] = []) -> XCUIApplication {
        launchHeroApp(arguments: ["-select-tab", "1"] + extra)
    }

    /// The grid's first tile, once its content landed. The grid is the one
    /// collection view on the For You root.
    private func firstTile(in app: XCUIApplication) -> XCUIElement {
        app.collectionViews.firstMatch.cells.firstMatch
    }

    @discardableResult
    private func openFirstTile(in app: XCUIApplication) -> Int {
        let baseline = heroProbe(in: app)?.sequence ?? 0
        let tile = firstTile(in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "the grid never showed a tile")
        tile.tap()
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no page arrived after the tap")
        return baseline
    }

    // MARK: - S01 + D01: open by tap, home by tap-back — the animator's own leg

    /// Three rounds, because the second open is where reuse bugs live (the
    /// reused-screen page instruction, the warm-up split) and one round
    /// proves only the cold path.
    func testOpenAndTapBackLeavesNothingBehind() {
        let app = launchOnForYou()
        waitForHeroSettle(in: app, after: 0, "the audit never published at launch")

        for round in 1...3 {
            let baseline = openFirstTile(in: app)
            let opened = waitForHeroSettle(in: app, after: baseline,
                                           "round \(round): the open never settled")
            assertHeroResidueClear(opened, "round \(round): after the open")
            attachHeroEvidence(app, name: "s01-round\(round)-open")

            let beforeReturn = opened?.sequence ?? 0
            app.navigationBars.buttons.firstMatch.tap()
            let returned = waitForHeroSettle(in: app, after: beforeReturn,
                                             "round \(round): the tap-back never settled")
            assertHeroResidueClear(returned, "round \(round): after the tap-back")
            XCTAssertTrue(firstTile(in: app).waitForExistence(timeout: 5),
                          "round \(round): the grid did not come back")
            attachHeroEvidence(app, name: "d01-round\(round)-returned")
        }
    }

    // MARK: - D04: the horizontal grab, committed

    func testAHorizontalGrabFliesThePostHome() {
        let app = launchOnForYou()
        waitForHeroSettle(in: app, after: 0)
        let baseline = openFirstTile(in: app)
        waitForHeroSettle(in: app, after: baseline)

        let before = heroProbe(in: app)?.sequence ?? 0
        app.swipeRight()
        let returned = waitForHeroSettle(in: app, after: before, "the grab never settled")
        assertHeroResidueClear(returned, "after a committed horizontal grab")
        XCTAssertTrue(firstTile(in: app).waitForExistence(timeout: 5),
                      "the grab did not land on the grid")
        attachHeroEvidence(app, name: "d04-grab-committed")
    }

    // MARK: - D02: the vertical grab, committed (the forward-only contract)

    func testAVerticalGrabFliesThePostHome() {
        let app = launchOnForYou()
        waitForHeroSettle(in: app, after: 0)
        let baseline = openFirstTile(in: app)
        waitForHeroSettle(in: app, after: baseline)

        let before = heroProbe(in: app)?.sequence ?? 0
        // From the upper half: a downward swipe from the middle travels the
        // pager's territory, and the pager is forward-only — the grab claims
        // it — but starting high keeps clear of the composer's strip.
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05,
                   thenDragTo: app.windows.firstMatch
                       .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                   withVelocity: 1400, thenHoldForDuration: 0)
        let returned = waitForHeroSettle(in: app, after: before, "the vertical grab never settled")
        assertHeroResidueClear(returned, "after a committed vertical grab")
        XCTAssertTrue(firstTile(in: app).waitForExistence(timeout: 5))
        attachHeroEvidence(app, name: "d02-vertical-grab-committed")
    }

    // MARK: - D03/D05: the cancelled grab — the page must come back WHOLE

    /// The leak-critical path (settlement plan L4): a short drag below the
    /// completion threshold, released — the page stays, and nothing the
    /// staging built survives the cancel. Three rounds: a cancel that leaks
    /// shows on the SECOND attempt as residue, not on the first.
    func testACancelledGrabRestoresThePage() {
        let app = launchOnForYou()
        waitForHeroSettle(in: app, after: 0)
        let baseline = openFirstTile(in: app)
        waitForHeroSettle(in: app, after: baseline)

        for round in 1...3 {
            let before = heroProbe(in: app)?.sequence ?? 0
            let start = app.windows.firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            // ~60pt of a 402pt span is progress ≈ 0.15 — under the 0.35
            // threshold, and a slow release stays under flick speed: cancel.
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0)),
                        withVelocity: 200, thenHoldForDuration: 0.15)
            let settled = waitForHeroSettle(in: app, after: before,
                                            "round \(round): the cancel never settled")
            assertHeroResidueClear(settled, "round \(round): after a cancelled grab")
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.exists,
                          "round \(round): the page left on a cancelled grab")
            attachHeroEvidence(app, name: "d03-round\(round)-cancelled")
        }

        app.navigationBars.buttons.firstMatch.tap()
        waitForHeroSettle(in: app, after: heroProbe(in: app)?.sequence ?? 0)
    }

    // MARK: - The MEDIA hero, hybrid: scripted open, real-finger dismissal

    /// A guaranteed media flight (the scripted opener only fires once a COVER
    /// loaded), closed by a real horizontal grab — the media-hero half of
    /// what `testAHorizontalGrabFliesThePostHome` does for the card family.
    func testAMediaHeroGrabbedHomeByARealFinger() {
        let app = launchOnForYou(extra: ["-foryou-open", "0"])
        // The opener taps by itself; wait for the pushed page, then settle.
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 30),
                      "the scripted opener never opened post 0")
        let opened = waitForHeroSettle(in: app, after: 0, timeout: 30,
                                       "the media open never settled")
        assertHeroResidueClear(opened, "after the scripted media open")
        attachHeroEvidence(app, name: "s01-media-open")

        let before = opened?.sequence ?? 0
        app.swipeRight()
        let returned = waitForHeroSettle(in: app, after: before,
                                         "the media hero grab never settled")
        assertHeroResidueClear(returned, "after grabbing the media hero home")
        XCTAssertTrue(firstTile(in: app).waitForExistence(timeout: 5))
        attachHeroEvidence(app, name: "d04-media-hero-returned")
    }

    /// The same media flight, thrown home DOWNWARD — the forward-only
    /// contract on the post the hero actually flies for.
    func testAMediaHeroGrabbedHomeVertically() {
        let app = launchOnForYou(extra: ["-foryou-open", "0"])
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 30),
                      "the scripted opener never opened post 0")
        let opened = waitForHeroSettle(in: app, after: 0, timeout: 30)
        assertHeroResidueClear(opened, "after the scripted media open")

        let before = opened?.sequence ?? 0
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05,
                   thenDragTo: app.windows.firstMatch
                       .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                   withVelocity: 1400, thenHoldForDuration: 0)
        let returned = waitForHeroSettle(in: app, after: before,
                                         "the vertical media grab never settled")
        assertHeroResidueClear(returned, "after the vertical media hero grab")
        XCTAssertTrue(firstTile(in: app).waitForExistence(timeout: 5))
        attachHeroEvidence(app, name: "d02-media-hero-vertical")
    }

    // MARK: - D06: dismiss after paging away — the landing retargets

    /// Open the first post, page forward through the feed, then grab home:
    /// the flight must land on the grid (scrolled to whatever the feed
    /// settled on — the exact slot arithmetic is pinned in
    /// `DismissalReturnMatrixTests`; this pins that the whole journey leaves
    /// nothing behind on screen).
    func testDismissingAfterPagingAwayStillLandsClean() {
        let app = launchOnForYou()
        waitForHeroSettle(in: app, after: 0)
        let baseline = openFirstTile(in: app)
        waitForHeroSettle(in: app, after: baseline)

        for _ in 0..<3 {
            app.swipeUp()
        }
        let before = heroProbe(in: app)?.sequence ?? 0
        app.swipeRight()
        let returned = waitForHeroSettle(in: app, after: before,
                                         "the paged-away dismissal never settled")
        assertHeroResidueClear(returned, "after dismissing three pages in")
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5),
                      "the grid did not come back")
        attachHeroEvidence(app, name: "d06-paged-away-landing")
    }
}
