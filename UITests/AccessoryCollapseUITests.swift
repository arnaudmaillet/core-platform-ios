import XCTest

/// Does the tab bar's band actually minimize under a real finger, on every
/// screen that puts its selector in a `UITabAccessory`?
///
/// # Why this is a UITest and not a unit test or a scripted scroll
///
/// ⚠️ **`setContentOffset` DOES NOT MINIMIZE THE BAR.** Measured on all three
/// accessory surfaces — For You included, which the viewer had already
/// confirmed collapsing on a real iPhone: `env=regular w=360` before a 240pt
/// programmatic scroll and `env=regular w=360` after. UIKit drives
/// `tabBarMinimizeBehavior` off a drag, so the only honest driver in this repo
/// is an XCUITest gesture. A scripted-scroll check would have reported three
/// working screens as broken, and — worse, had it been written first — a
/// broken one as working the day someone made it pass.
///
/// The band's state is read from `AccessoryCollapseAudit`'s probe rather than
/// from screen geometry, because the geometry lies too: `tabBar.frame` is
/// 402x83 both minimized and not. What moves is the accessory's environment
/// trait, `.regular` (360pt) → `.inline` (234pt).
final class AccessoryCollapseUITests: XCTestCase {

    /// The three tabs whose root screen hosts its selector in the accessory.
    /// Indices into `AppTab.allCases` — `-select-tab` takes an INDEX, and a
    /// name is a silent no-op that lands on Maps and fakes a missing selector.
    private static let accessorySurfaces: [(name: String, tab: Int)] = [
        ("For You", 1), ("Messages", 2), ("Profile", 3),
    ]

    override func setUp() { continueAfterFailure = false }

    /// Every distinct probe line seen since the last `resetTrace()`. A single
    /// last-seen line says the band is wrong; the trace says what it did.
    private var trace: [String] = []
    private func resetTrace() { trace = [] }
    private var traceText: String { "\n  " + trace.joined(separator: "\n  ") }

    /// ⚠️ **WHY THE WAY BACK IS NOT AN ASSERTION HERE.**
    ///
    /// The collapse is deterministic in the simulator. The expand is not — and
    /// not per screen either, which is what rules out a wiring explanation.
    /// Three runs of THIS test, same build, same gestures:
    ///
    ///     run 5   For You: expanded (1 drag)   Messages: DID NOT expand
    ///     run 6   For You: DID NOT expand      (never reached the others)
    ///     run 8   For You: expanded (1 drag)   Messages: DID NOT expand
    ///                                          Profile:  expanded (2 drags)
    ///
    /// In every non-expanding case the page had scrolled all the way back to
    /// its top (`offset=-116` against `room=3521`) with the band still
    /// `inline`: the scroll happened and UIKit did not react to it. Same screen,
    /// same build, opposite outcomes one run apart.
    ///
    /// This is the simulator misbehaviour already recorded in
    /// `SelectorAccessory` — the docking animation was chased through a whole
    /// session here and then found working, unchanged, on a real iPhone.
    /// Asserting it would make the suite red for the simulator rather than for
    /// the app. The Messages leg is the one to re-check on device: it has not
    /// expanded in any run recorded here.
    ///
    /// So the gate is everything that IS deterministic — armed, the visible
    /// page named, and the band minimizing on a scroll down — and the way back
    /// is printed for whoever is reading the run.
    private var expandReport: [String] = []

    func testEveryAccessorySelectorRidesTheScroll() {
        expandReport = []
        // An ACTIVITY, not a `print`: test-process stdout does not survive into
        // the xcresult in any readable form, and a report nobody can find is
        // the same as no report.
        defer {
            XCTContext.runActivity(named: "way back — " + expandReport.joined(separator: " | ")) { _ in }
        }
        for surface in Self.accessorySurfaces {
            let app = XCUIApplication()
            app.launchArguments = ["-mock-auto-login", "-accessory-collapse-probe",
                                   "-select-tab", String(surface.tab)]
            app.launch()
            resetTrace()


            // ⚠️ WAITED FOR AS ONE CONDITION, not asserted on the first
            // `env=regular` sample. The accessory is installed a beat before
            // the page has a scroller to name, so the first resting sample
            // legitimately carries `named=0` — and asserting on it failed the
            // inbox for a state it was two samples away from leaving. The
            // failure message carries the last line, so a real never-registers
            // still says exactly which field stayed 0.
            let resting = probe(in: app, timeout: 25) {
                $0.environment == "regular" && $0.isArmed
                    && $0.hasNamedScroller && $0.namedTheVisibleOne
            }
            guard let resting else {
                XCTFail("\(surface.name): never reached a resting band with an armed "
                    + "minimize and the visible page registered — "
                    + "last probe \(lastSeen(in: app) ?? "none")\(traceText)")
                app.terminate()
                continue
            }

            swipe(app, from: 0.75, to: 0.25)
            let minimized = probe(in: app, timeout: 8) { $0.environment == "inline" }
            XCTAssertNotNil(minimized,
                            "\(surface.name): the band did not minimize on a scroll down — "
                            + "last probe \(lastSeen(in: app) ?? "none")\(traceText)")
            if let minimized {
                XCTAssertLessThan(minimized.accessoryWidth, resting.accessoryWidth,
                                  "\(surface.name): env went inline but the accessory kept its width")
            }

            // The way back is REPORTED, NOT ASSERTED, and the reason is
            // measured rather than assumed — see `expandIsReportedNotAsserted`.
            var expanded: Band?
            var drags = 0
            while expanded == nil, drags < 3 {
                drags += 1
                swipe(app, from: 0.3, to: 0.8)
                expanded = probe(in: app, timeout: 6) { $0.environment == "regular" }
            }
            expandReport.append(expanded == nil
                ? "\(surface.name): DID NOT expand in 3 drags"
                : "\(surface.name): expanded after \(drags) drag\(drags == 1 ? "" : "s")")
            app.terminate()
        }
    }

    // MARK: - The probe channel

    private struct Band {
        let environment: String
        let accessoryWidth: Double
        let isArmed: Bool
        let hasNamedScroller: Bool
        let namedTheVisibleOne: Bool

        init?(_ identifier: String) {
            guard identifier.hasPrefix("accessory;") else { return nil }
            var fields: [String: String] = [:]
            for pair in identifier.split(separator: ";").dropFirst() {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            environment = fields["env"] ?? "?"
            accessoryWidth = Double(fields["w"] ?? "") ?? -1
            isArmed = fields["armed"] == "1"
            hasNamedScroller = fields["named"] == "1"
            namedTheVisibleOne = fields["onscreen"] == "1"
        }
    }

    private func lastSeen(in app: XCUIApplication) -> String? {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'accessory;'"))
            .firstMatch.identifier
    }

    /// Polls the probe until `matches` holds. Polling rather than one read: the
    /// audit samples at 4Hz and the trait flips on UIKit's own clock, so the
    /// first identifier after a gesture is routinely the pre-gesture one.
    private func probe(in app: XCUIApplication, timeout: TimeInterval,
                       matches: (Band) -> Bool) -> Band? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let identifier = lastSeen(in: app) {
                let comparable = identifier.split(separator: ";")
                    .filter { !$0.hasPrefix("seq=") && !$0.hasPrefix("offset=") }
                    .joined(separator: ";")
                if trace.last?.split(separator: ";").filter({ !$0.hasPrefix("seq=") && !$0.hasPrefix("offset=") })
                    .joined(separator: ";") != comparable {
                    trace.append(identifier)
                }
                if let band = Band(identifier), matches(band) { return band }
            }
            usleep(150_000)
        }
        return nil
    }

    /// A drag, not `swipeUp()`. The convenience swipe is a flick whose distance
    /// XCUITest chooses; the band's behaviour is measured against a scroll the
    /// test controls the length of.
    private func swipe(_ app: XCUIApplication, from start: CGFloat, to end: CGFloat) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end)))
    }
}
