import XCTest

/// Does the band survive a pop, or is it taken down and put back?
///
/// ⚠️ **THE GAP IS INVISIBLE TO EVERY STATIC CHECK.** Before and after the
/// transition the accessory is present and correct; what the viewer complains
/// about happens only in between, and only for a few frames. So this samples
/// the probe continuously ACROSS the gesture and asks whether the slot was ever
/// empty — a question no screenshot of either end can answer.
final class AccessoryHandOverUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testPoppingBackToAScreenWithABandNeverEmptiesTheSlot() {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login", "-accessory-collapse-probe",
                               "-select-tab", "1",
                               "-open-search", "-search-query", "paris", "-search-submit"]
        app.launch()

        // The search results' own band, up and settled.
        XCTAssertTrue(waitForProbe(in: app, timeout: 25) {
            $0.contains("surface=SearchResultsViewController") && $0.contains("env=regular")
        }, "the search results never showed a band — last \(lastProbe(in: app) ?? "none")")

        // A real edge swipe: the interactive pop is the path that defers chrome,
        // and the one the viewer filmed.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)))

        // Sample hard across the transition and its tail.
        var sawEmpty: String?
        var sawForYou = false
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let line = lastProbe(in: app) {
                if line.contains("env=no-accessory") { sawEmpty = sawEmpty ?? line }
                if line.contains("surface=ForYouViewController"), line.contains("env=regular") {
                    sawForYou = true
                    break
                }
            }
            usleep(60_000)
        }

        XCTAssertTrue(sawForYou, "the pop never landed on For You — last \(lastProbe(in: app) ?? "none")")
        XCTAssertNil(sawEmpty, "the band was taken down mid-pop: \(sawEmpty ?? "")")
        app.terminate()
    }

    private func lastProbe(in app: XCUIApplication) -> String? {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'accessory;'"))
            .firstMatch.identifier
    }

    private func waitForProbe(in app: XCUIApplication, timeout: TimeInterval,
                              matches: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = lastProbe(in: app), matches(line) { return true }
            usleep(120_000)
        }
        return false
    }
}
