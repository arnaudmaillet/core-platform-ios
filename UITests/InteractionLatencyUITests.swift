import XCTest

/// The regression guard of #2116: the routes whose response time a fix in
/// that audit brought down, driven under `-interaction-latency`, each read
/// back from the harness's probe (`latency;…;last=<response>:<ms>`).
///
/// The sibling of `PresentationBudgetUITests`, which times the turn that
/// BUILDS a screen. This one times input → first frame, which is what the
/// 100 ms rule is about (`dev/RESPONSIVENESS_AUDIT.md`, charter P16).
///
/// # Ratchets
///
/// A route's `ceilingMs` is what it measures today under XCUITest (whose
/// accessibility runtime roughly doubles a turn), best of `repeats` warm
/// runs, with head-room for a CI runner. A route fails only when it gets
/// WORSE; the PR that brings it down lowers its ceiling. The 100 ms target
/// is the audit's, judged on a device and on the simulator with real taps,
/// not here.
///
/// Runs on demand, like the presentation sweep: not in the required checks.
final class InteractionLatencyUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    private struct Route {
        let name: String
        let arguments: [String]
        /// One measured action, after the launch has settled; false when
        /// what it taps was not on screen.
        let act: @MainActor (XCUIApplication) -> Bool
        /// Puts the screen back for the next repeat.
        let undo: (@MainActor (XCUIApplication) -> Void)?
        let ceilingMs: Int
        /// The sub-issue of #2116 that owns the route.
        let issue: String
    }

    /// By label: the shell lays invisible menu buttons over its tab items
    /// (the "+" menu, the profile switcher), so an index can land on one.
    @MainActor private static func tab(_ label: String) -> @MainActor (XCUIApplication) -> Bool {
        { app in
            let button = app.tabBars.buttons[label]
            guard button.waitForExistence(timeout: 10) else { return false }
            button.tap()
            return true
        }
    }

    @MainActor private static let back: @MainActor (XCUIApplication) -> Void = { app in
        app.navigationBars.buttons.firstMatch.tap()
        sleep(2)
    }

    /// Ceilings: the 5 November 2026 calibration, debug build, iPhone 18 Pro
    /// simulator, under XCUITest, best warm run of two calibration passes
    /// (tab → Messages 156 ms, → Profile 229 ms, thread 417–623 ms, Security
    /// 146–264 ms), with ~2x head-room: XCUITest's numbers swing by half
    /// between passes on the same code.
    @MainActor private static let routes: [Route] = [
        Route(name: "tab → messages", arguments: ["-select-tab", "1"],
              act: tab("Messages"), undo: { app in _ = tab("For You")(app); sleep(2) },
              ceilingMs: 350, issue: "#2117 (inbox reload), #2120 (band)"),
        Route(name: "tab → profile", arguments: ["-select-tab", "1"],
              act: tab("Profile"), undo: { app in _ = tab("For You")(app); sleep(2) },
              ceilingMs: 450, issue: "#2118 (tab faces), #2120 (band)"),
        Route(name: "messages → thread", arguments: ["-select-tab", "2"],
              act: { app in
                  let cell = app.cells.firstMatch
                  guard cell.waitForExistence(timeout: 20) else { return false }
                  cell.tap()
                  return true
              },
              undo: back, ceilingMs: 1100, issue: "#2121 (thread), #2127 (gate lookup)"),
        Route(name: "settings → security", arguments: ["-select-tab", "3"],
              act: { app in
                  let gear = app.buttons["Settings"]
                  if gear.waitForExistence(timeout: 10) {
                      gear.tap()
                      sleep(2)
                  }
                  let row = app.staticTexts["Security and Login"]
                  guard row.waitForExistence(timeout: 10) else { return false }
                  row.tap()
                  return true
              },
              undo: { app in back(app); back(app) }, ceilingMs: 550, issue: "#2128 (LAContext)"),
    ]

    private static let repeats = 3

    @MainActor func testEveryGuardedRouteStaysUnderItsCeiling() {
        for route in Self.routes {
            let app = XCUIApplication()
            app.launchArguments = ["-mock-auto-login", "-interaction-latency"] + route.arguments
            app.launch()
            defer { app.terminate() }
            sleep(5)
            var best: Int?
            var seen: [String] = []
            for run in 1...Self.repeats {
                let before = readProbe(in: app)?.count ?? 0
                guard route.act(app) else {
                    XCTFail("\(route.name) #\(run): what the route taps was not on screen")
                    break
                }
                sleep(2)
                guard let probe = readProbe(in: app), probe.count > before else {
                    XCTFail("\(route.name) #\(run): no new reading — the harness saw no response")
                    route.undo?(app)
                    continue
                }
                seen.append("\(probe.last):\(probe.lastMs)")
                // The first run is the cold one: its cost belongs to #2123.
                if run > 1 { best = min(best ?? .max, probe.lastMs) }
                route.undo?(app)
            }
            guard let best else {
                XCTFail("\(route.name): no warm reading (\(seen))")
                continue
            }
            // The calibration line: what a ratchet is set from.
            print("[latency-guard] \(route.name) best=\(best)ms ceiling=\(route.ceilingMs)ms runs=\(seen)")
            XCTAssertLessThanOrEqual(
                best, route.ceilingMs,
                "\(route.name): got WORSE than its ratchet of \(route.ceilingMs)ms (tracked by \(route.issue)) — runs \(seen)"
            )
        }
    }

    // MARK: - Probe

    private struct LatencyProbe {
        let count: Int
        let last: String
        let lastMs: Int
    }

    private func readProbe(in app: XCUIApplication) -> LatencyProbe? {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'latency;'"))
            .firstMatch
        guard element.exists else { return nil }
        var values: [String: String] = [:]
        for pair in element.identifier.split(separator: ";").dropFirst() {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
        }
        // `last=<response>:<ms>`, the response itself holding a colon
        // (`appear:ProfileViewController`): the ms is after the last one.
        let last = values["last"] ?? ""
        let ms = last.split(separator: ":").last.flatMap { Int($0) } ?? 0
        let name = last.split(separator: ":").dropLast().joined(separator: ":")
        return LatencyProbe(count: Int(values["n"] ?? "") ?? 0, last: name, lastMs: ms)
    }
}
