import XCTest

/// The sweep behind `dev/PRESENTATION_CHARTER.md` P2: every route the app can
/// open from a launch argument or a first tap is opened under
/// `-presentation-budget`, and the run-loop turn that brought each screen on
/// is read back from the harness's probe. The app's own harness does the
/// timing and the stack sampling; this test only drives the routes, so a
/// failure names the screen, its turn in ms and the app frames that were
/// hottest while it ran.
///
/// # Two numbers per route
///
/// `simulatorBudgetMs` is the target: what every route must come down to.
/// A route's `ceilingMs` is a RATCHET: the turn it measures today, with
/// head-room, on the routes the charter's fix PRs have not reached yet. A
/// route with a ceiling fails only when it gets WORSE; a route without one
/// fails when it goes over the target. A fix PR lowers or removes the
/// ceiling of the route it fixes — that is how the sweep stays green on every
/// merge and still refuses a regression.
///
/// # Why the budget is not the charter's 8 ms
///
/// 8 ms is a device number (iPhone SE 2nd gen, release build). This suite
/// runs a DEBUG build on a simulator: no optimizer, and an Apple-silicon host
/// that is faster than the SE on some paths and slower on others (a debug
/// Swift collection walk can be 5x a release one). The simulator target is
/// therefore calibrated on measured turns of screens that DO obey the
/// charter, with head-room for a CI runner, and is not derived from 8 ms.
final class PresentationBudgetUITests: XCTestCase {
    /// Milliseconds per screen turn, debug build on the simulator.
    private static let simulatorBudgetMs = 40

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    // MARK: - Routes

    private struct Route {
        let name: String
        let arguments: [String]
        /// The in-app steps after the launch has settled; false when the
        /// element a step needed was not on screen.
        let drive: (@MainActor (XCUIApplication) -> Bool)?
        /// Screen turns this route must have measured — the denominator a
        /// silent run needs.
        let expectedScreens: Int
        /// The ratchet, in ms; nil holds the route to the budget itself.
        let ceilingMs: Int?
        /// Which charter PR owns the route's current cost.
        let trackedBy: String?

        init(_ name: String, _ arguments: [String], expectedScreens: Int = 1,
             ceilingMs: Int? = nil, trackedBy: String? = nil,
             drive: (@MainActor (XCUIApplication) -> Bool)? = nil) {
            self.name = name
            self.arguments = arguments
            self.expectedScreens = expectedScreens
            self.ceilingMs = ceilingMs
            self.trackedBy = trackedBy
            self.drive = drive
        }
    }

    /// Taps the first cell on screen (a For You tile, a conversation row, a
    /// gallery tile), waits on the pushed screen, and pops it.
    @MainActor private static let firstCellThenBack: @MainActor (XCUIApplication) -> Bool = { app in
        let cell = app.cells.firstMatch
        guard cell.waitForExistence(timeout: 20) else { return false }
        cell.tap()
        guard app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10) else { return false }
        sleep(2)
        app.navigationBars.buttons.firstMatch.tap()
        sleep(2)
        return true
    }

    /// Opens the "+" menu from the tab bar and picks the named item.
    @MainActor private static func createMenu(_ item: String) -> @MainActor (XCUIApplication) -> Bool {
        { app in
            let plus = app.tabBars.buttons.allElementsBoundByIndex.last
            guard let plus, plus.waitForExistence(timeout: 10) else { return false }
            plus.tap()
            let choice = app.buttons[item]
            guard choice.waitForExistence(timeout: 5) else { return false }
            choice.tap()
            sleep(3)
            return true
        }
    }

    /// Ceilings are the 24 September 2026 sweep (debug build, iPhone 18 Pro
    /// simulator, under XCUITest — which itself roughly doubles a turn), best
    /// of two, with ~1.6x head-room. Each names the charter PR that owns
    /// bringing it down.
    @MainActor private static let routes: [Route] = [
        Route("for-you → post → back", ["-select-tab", "1"],
              ceilingMs: 650, trackedBy: "charter PR 5b (feed first layout)", drive: firstCellThenBack),
        Route("messages → thread → back", ["-select-tab", "2"],
              ceilingMs: 950, trackedBy: "charter PR 5b (thread first layout)", drive: firstCellThenBack),
        Route("profile → post → back", ["-select-tab", "3"],
              ceilingMs: 550, trackedBy: "charter PR 5b (feed first layout)", drive: firstCellThenBack),
        // PR 3 (#193, lazy pager pages): 3 lists rendered at push → 1.
        // Harness alone 212–334 ms on a loaded host; what remains is the one
        // page's skeleton rows and the accessory's settle.
        Route("profile → relationships", ["-select-tab", "3", "-profile-relationships"],
              ceilingMs: 550, trackedBy: "charter PR 3 (done); what remains is the page itself"),
        Route("profile → share sheet", ["-select-tab", "3", "-profile-share-demo"],
              ceilingMs: 350, trackedBy: "charter PR 7"),
        // 313 ms on a quiet host, 737 ms with three builds running beside the
        // sweep: the ratchet is for regressions of the CODE, so the routes
        // the fix PRs have not reached carry ~2.5x head-room, not 1.6x.
        Route("map pin → feed", ["-select-tab", "0", "-maps-open-first-pin"],
              ceilingMs: 800, trackedBy: "charter PR 5b"),
        Route("+ → text post", ["-select-tab", "1"],
              ceilingMs: 550, trackedBy: "charter PR 5c", drive: createMenu("Text Post")),
        // PR 2 (the picker's library off the main actor): 514 → ~200 ms
        // under XCUITest. The remaining cost is the sheet's own presentation.
        Route("+ → upload media", ["-select-tab", "1"],
              ceilingMs: 320, trackedBy: "charter PR 2 (done); what remains is the sheet", drive: createMenu("Upload Media")),
    ]

    /// A route is opened this many times and judged on its BEST run: a turn's
    /// cost has a floor (the work) and noise above it (a cold cache, the
    /// runner's own first launch, the host), and the ratchet is about the
    /// floor. One run of the first route measured 376 ms and then 640 ms on
    /// the same code; the best of two is stable to ~15%.
    private static let attemptsPerRoute = 2

    @MainActor func testEveryRouteOnTheSweepStaysUnderItsCeiling() {
        var measured = 0
        for route in Self.routes {
            var best: BudgetProbe?
            for attempt in 1...Self.attemptsPerRoute {
                guard let probe = open(route, attempt: attempt) else { continue }
                if best == nil || probe.worstMs < best!.worstMs { best = probe }
            }
            guard let probe = best else {
                XCTFail("\(route.name): no attempt produced a reading")
                continue
            }
            measured += probe.screens
            XCTAssertGreaterThanOrEqual(
                probe.screens, route.expectedScreens,
                "\(route.name): only \(probe.screens) screen turn(s) measured — the route did not open what it should"
            )
            let owner = route.trackedBy.map { " (tracked by \($0))" } ?? ""
            let evidence = "best of \(Self.attemptsPerRoute): worst turn \(probe.worst)ms"
                + (probe.hot.isEmpty ? "" : ", hottest app frames: \(probe.hot)")
            if let ceiling = route.ceilingMs {
                XCTAssertLessThanOrEqual(
                    probe.worstMs, ceiling,
                    "\(route.name): got WORSE than its ratchet of \(ceiling)ms\(owner) — \(evidence)"
                )
            } else {
                XCTAssertEqual(
                    probe.over, 0,
                    "\(route.name): \(probe.over) screen turn(s) over \(Self.simulatorBudgetMs)ms — \(evidence)"
                )
            }
        }
        XCTAssertGreaterThanOrEqual(measured, Self.routes.count,
                                    "the sweep measured \(measured) screen turns across \(Self.routes.count) routes")
    }

    /// One launch of a route: the app up, the launch settled, the in-app
    /// steps driven, the probe read, the app down. Nil when the harness or
    /// the route did not come up (each reported as its own failure).
    @MainActor private func open(_ route: Route, attempt: Int) -> BudgetProbe? {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mock-auto-login", "-presentation-budget",
            "-presentation-budget-ms", String(Self.simulatorBudgetMs),
        ] + route.arguments
        app.launch()
        defer { app.terminate() }

        guard probeElement(in: app).waitForExistence(timeout: 30) else {
            XCTFail("\(route.name) #\(attempt): no budget probe — the harness did not install")
            return nil
        }
        // The launch is exempt inside the harness; the route's own screens
        // come on after it, by argument or by the taps below.
        sleep(4)
        if let drive = route.drive, !drive(app) {
            XCTFail("\(route.name) #\(attempt): the in-app step was not on screen")
            return nil
        }
        sleep(1)
        guard let probe = readProbe(in: app) else {
            XCTFail("\(route.name) #\(attempt): the probe vanished (state=\(app.state.rawValue)) — a trap or a crash")
            return nil
        }
        return probe
    }

    // MARK: - Probe

    private struct BudgetProbe {
        let turns: Int
        let screens: Int
        let over: Int
        /// `Class:ms` of the worst screen turn.
        let worst: String
        let worstMs: Int
        let hot: String
    }

    private func probeElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'budget;'"))
            .firstMatch
    }

    private func readProbe(in app: XCUIApplication) -> BudgetProbe? {
        let element = probeElement(in: app)
        guard element.exists else { return nil }
        var values: [String: String] = [:]
        for pair in element.identifier.split(separator: ";").dropFirst() {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
        }
        let worst = values["worst"] ?? "?"
        return BudgetProbe(
            turns: Int(values["turns"] ?? "") ?? 0,
            screens: Int(values["screens"] ?? "") ?? 0,
            over: Int(values["over"] ?? "") ?? 0,
            worst: worst,
            worstMs: worst.split(separator: ":").last.flatMap { Int($0) } ?? 0,
            hot: values["hot"] ?? ""
        )
    }
}
