import XCTest

/// The mid-air catch (plan ID D07): the scripted interrupt drives BOTH
/// outcomes deterministically — the reversal is the one branch that must give
/// a hoisted surface back — and a best-effort real catch exercises the
/// freeze-on-contact path with an actual finger.
final class HeroInterruptionUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// `-zoom-interrupt` arms on the NEXT flight: `-foryou-open 0` supplies
    /// it. The app pauses the flight at +0.15s, scrubs, and decides at +0.30s
    /// — no finger, no timing race against the 0.42s spring.
    private func runScriptedInterrupt(_ mode: String) {
        let app = launchHeroApp(arguments: [
            "-select-tab", "1", "-foryou-open", "0", "-zoom-interrupt", mode,
        ])
        let settled = waitForHeroSettle(in: app, after: 0, timeout: 40,
                                        "the \(mode) interrupt never settled")
        assertHeroResidueClear(settled, "after a scripted \(mode) of a caught flight")
        attachHeroEvidence(app, name: "d07-scripted-\(mode)")

        if mode == "cancel" {
            // The reversal put the grid back: a tile is reachable again, and a
            // second open still works — the owner-side per-flight state was
            // released, not left locked (the defect `onPresentationCancelled`
            // exists for).
            let tile = app.collectionViews.firstMatch.cells.firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 10),
                          "the reversed present did not restore the grid")
            let before = heroProbe(in: app)?.sequence ?? 0
            tile.tap()
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10),
                          "the tap after a reversed flight opened nothing — per-flight state stayed locked")
            assertHeroResidueClear(
                waitForHeroSettle(in: app, after: before),
                "after re-opening past a reversed flight"
            )
            attachHeroEvidence(app, name: "d07-reopen-after-cancel")
        }
    }

    func testACaughtFlightFinishedMidAirLandsClean() {
        runScriptedInterrupt("finish")
    }

    func testACaughtFlightReversedMidAirRestoresTheGridWhole() {
        runScriptedInterrupt("cancel")
    }

    /// Best-effort REAL catch: tap a tile and press the flying card within
    /// its 0.42s spring. Injection latency makes any single attempt a coin
    /// toss, so this retries — the only test in the hero suites allowed to —
    /// and skips honestly if no attempt connected. The deterministic gate for
    /// the outcome is the scripted pair above; what only this can exercise is
    /// a genuine touch-down freeze plus drag through the real recognizers.
    func testARealFingerCanCatchAndThrowBackAFlight() throws {
        let app = launchHeroApp(arguments: ["-select-tab", "1"])
        waitForHeroSettle(in: app, after: 0)

        var connected = false
        for attempt in 1...4 {
            let tile = app.collectionViews.firstMatch.cells.firstMatch
            // Existence AND hittability, both non-throwing: after a previous
            // attempt the grid can be mid-settle with the cell occluded, and
            // `tap()` on a non-hittable element ABORTS the test — which is a
            // harness failure, not a finding, in a best-effort probe.
            guard tile.waitForExistence(timeout: 15), tile.isHittable else {
                app.swipeDown()
                continue
            }
            let before = heroProbe(in: app)?.sequence ?? 0
            tile.tap()
            // Press immediately where the card is flying and drag DOWN — on
            // the present leg a downward drag reverses the push.
            let mid = app.windows.firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            mid.press(forDuration: 0.25,
                      thenDragTo: mid.withOffset(CGVector(dx: 0, dy: 300)),
                      withVelocity: 1200, thenHoldForDuration: 0)
            let settled = waitForHeroSettle(in: app, after: before, timeout: 25,
                                            "attempt \(attempt) never settled")
            assertHeroResidueClear(settled, "after real-catch attempt \(attempt)")
            attachHeroEvidence(app, name: "d07-real-attempt\(attempt)")

            // Whichever way it went, recover to the grid for the next attempt.
            if app.navigationBars.buttons.firstMatch.exists {
                let seq = heroProbe(in: app)?.sequence ?? 0
                app.navigationBars.buttons.firstMatch.tap()
                waitForHeroSettle(in: app, after: seq)
            } else {
                // The drag reversed the push mid-air: the catch connected.
                connected = true
                break
            }
        }
        try XCTSkipUnless(connected,
                          "no attempt caught the flight mid-air (injection latency) — "
                          + "the scripted -zoom-interrupt tests remain the deterministic gate")
    }
}
