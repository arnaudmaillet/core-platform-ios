import XCTest

/// Iteration is the test (plan IDs K1–K4, L4/L5 regressions): a single clean
/// cycle proves the paths; only repetition proves nothing ACCUMULATES. Every
/// cycle re-reads the audit census, so a leak fails on the cycle that leaks
/// it — with its number in the message — rather than as a fuzzy total at the
/// end.
final class HeroSoakUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - K1: open/close by real fingers, ten rounds, mixed dismissals

    func testTenMixedCyclesLeaveTheCensusFlat() {
        let app = launchHeroApp(arguments: ["-select-tab", "1"])
        waitForHeroSettle(in: app, after: 0)

        var playersAtRest: [Int] = []
        for cycle in 1...10 {
            let tile = app.collectionViews.firstMatch.cells.firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 20), "cycle \(cycle): no tile")
            let before = heroProbe(in: app)?.sequence ?? 0
            tile.tap()
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10),
                          "cycle \(cycle): the open failed")
            let opened = waitForHeroSettle(in: app, after: before,
                                           "cycle \(cycle): open never settled")
            assertHeroResidueClear(opened, "cycle \(cycle): after open")

            let beforeReturn = opened?.sequence ?? 0
            switch cycle % 3 {
            case 0: app.navigationBars.buttons.firstMatch.tap()
            case 1: app.swipeRight()
            default:
                app.windows.firstMatch
                    .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                    .press(forDuration: 0.05,
                           thenDragTo: app.windows.firstMatch
                               .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                           withVelocity: 1400, thenHoldForDuration: 0)
            }
            let returned = waitForHeroSettle(in: app, after: beforeReturn,
                                             "cycle \(cycle): return never settled")
            assertHeroResidueClear(returned, "cycle \(cycle): after return")
            playersAtRest.append(returned?.players ?? -1)

            if cycle == 1 || cycle == 10 {
                attachHeroEvidence(app, name: "k1-cycle\(cycle)-at-rest")
            }
        }

        // The resting player count must STABILIZE, not stay at its first
        // value: mixed dismissals land on different posts, the grid scrolls,
        // video rows realize, and the carousel retention window KEEPS clips —
        // all by design, all steps UP in the resting working set (measured:
        // 0,0,0,0,0,4,8,8,8,8 across ten cycles). What a leak looks like is
        // the curve still climbing at the end; what health looks like is a
        // plateau. So: the last three cycles agree, and the plateau stays
        // within a working set the decoders can even serve.
        let plateau = playersAtRest.suffix(3)
        XCTAssertEqual(Set(plateau).count, 1,
                       "resting players were still climbing at the end: \(playersAtRest)")
        XCTAssertLessThanOrEqual(plateau.max() ?? 0, 12,
                                 "the resting working set outgrew any sane decoder budget:"
                                 + " \(playersAtRest)")
    }

    // MARK: - K2: the app's own grab-cycle harness, audited from outside

    /// `-foryou-grab-cycles` repeats open→grab→return inside the app. The
    /// test's job is only to wait it out and read the census — plus the
    /// denominator: the audit heartbeat must show samples were actually
    /// taken while the cycles ran.
    func testScriptedGrabCyclesEndWithNothingAlive() {
        let app = launchHeroApp(arguments: [
            "-select-tab", "1", "-foryou-open", "0",
            "-foryou-demo-grab", "-foryou-grab-cycles", "4",
        ])
        // Every cycle is ~4s of scripted gestures; wait for a LATE settled
        // sample and then confirm stability over two more samples.
        var last = waitForHeroSettle(in: app, after: 0, timeout: 60)
        let deadline = Date().addingTimeInterval(90)
        var quietStreak = 0
        while Date() < deadline, quietStreak < 8 {
            guard let next = waitForHeroSettle(in: app, after: last?.sequence ?? 0,
                                               timeout: 30) else { break }
            quietStreak = next.transitionResidue == 0 ? quietStreak + 1 : 0
            last = next
        }
        XCTAssertGreaterThanOrEqual(quietStreak, 8,
                                    "the grab cycles never went quiet — something is still flying")
        assertHeroResidueClear(last, "after the scripted grab cycles")
        XCTAssertLessThanOrEqual(last?.players ?? 99, 6,
                                 "players exceeded the pool's budget after the soak")
        attachHeroEvidence(app, name: "k2-after-grab-cycles")
    }

    // MARK: - L4: the cancelled grab under the legacy backing

    /// Under `-avplayer-render` the donation physically removes the page's
    /// render view; a cancelled grab must give it back
    /// (`zoomReclaimLiveMediaView` — the settlement plan's cancel row).
    /// Repeated, because the first cancel leaving the page dead shows up as
    /// the SECOND cycle failing to play anything.
    func testCancelledGrabsUnderTheLegacyBackingKeepThePageAlive() {
        let app = launchHeroApp(arguments: ["-select-tab", "1", "-avplayer-render"])
        waitForHeroSettle(in: app, after: 0)
        let tile = app.collectionViews.firstMatch.cells.firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        let baseline = heroProbe(in: app)?.sequence ?? 0
        tile.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10))
        waitForHeroSettle(in: app, after: baseline)

        for round in 1...3 {
            let before = heroProbe(in: app)?.sequence ?? 0
            let start = app.windows.firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0)),
                        withVelocity: 200, thenHoldForDuration: 0.15)
            let settled = waitForHeroSettle(in: app, after: before,
                                            "round \(round): cancel never settled (legacy backing)")
            assertHeroResidueClear(settled, "round \(round): legacy-backing cancel")
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.exists,
                          "round \(round): the page left on a cancel")
            XCTAssertEqual(settled?.duplicates ?? -1, 0,
                           "round \(round): the reclaim minted a second player")
        }
        attachHeroEvidence(app, name: "l4-legacy-cancel-rounds")
    }

    // MARK: - Memory: the growth curve, measured

    /// `XCTMemoryMetric` around five open/close cycles. Reported into the
    /// result bundle rather than hard-asserted — the census above is the
    /// pass/fail; this is the curve a reviewer reads when the census moves.
    func testMemoryAcrossOpenCloseCycles() {
        let app = launchHeroApp(arguments: ["-select-tab", "1"])
        waitForHeroSettle(in: app, after: 0)
        XCTAssertTrue(app.collectionViews.firstMatch.cells.firstMatch
            .waitForExistence(timeout: 20))

        measure(metrics: [XCTMemoryMetric(application: app)]) {
            let tile = app.collectionViews.firstMatch.cells.firstMatch
            guard tile.waitForExistence(timeout: 10) else { return }
            let before = heroProbe(in: app)?.sequence ?? 0
            tile.tap()
            _ = app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10)
            waitForHeroSettle(in: app, after: before)
            let seq = heroProbe(in: app)?.sequence ?? 0
            app.swipeRight()
            waitForHeroSettle(in: app, after: seq)
        }
    }
}
