import XCTest

/// The probe's own health, plus the tree dump every suite here leans on when
/// a query stops matching.
///
/// Kept for the same reason `CarouselRetentionUITests` keeps its dump: "the
/// probe is missing" and "the probe is there and my query does not match it"
/// are indistinguishable from a failing assertion, and guessing between them
/// costs more than one run that simply looks.
final class HeroProbeDiagnosticsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The audit publishes, the census parses, `seq` advances, and a launch
    /// WITHOUT the flag publishes nothing — the denominator that keeps every
    /// suite honest about what a green run proves.
    func testTheProbePublishesAndAdvances() throws {
        let app = launchHeroApp()
        let first = waitForHeroSettle(in: app, after: 0, "the audit never published")
        let probe = try XCTUnwrap(first, "no parseable census")
        XCTAssertGreaterThan(probe.sequence, 0)

        let second = waitForHeroSettle(in: app, after: probe.sequence,
                                       "seq never advanced — the audit stopped sampling")
        XCTAssertGreaterThan(second?.sequence ?? 0, probe.sequence)
        attachHeroEvidence(app, name: "probe-diagnostics-settled")
    }

    func testWithoutTheFlagThereIsNoProbe() {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 20)
        XCTAssertFalse(heroProbeElement(in: app).waitForExistence(timeout: 3),
                       "a probe with no -hero-audit means the gate broke")
    }

    /// Prints the head of the tree — run by hand when a query stops matching.
    func testDumpTheTree() {
        let app = launchHeroApp(arguments: ["-select-tab", "1"])
        _ = waitForHeroSettle(in: app, after: 0)
        let tree = app.debugDescription
        print("=== HERO PROBE PRESENT: \(tree.contains("hero;")) ===")
        print(tree.prefix(4000))
    }
}
