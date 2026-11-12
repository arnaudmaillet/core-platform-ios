import XCTest

/// The likes balance stands where likes are spent or earned, and leaves the
/// screens where it never moves (#2336, the owner 2026-11-12): For You and
/// the own profile keep it; Messages (no heart, no spend, no claim) and the
/// map (a tap opens the post, which wears it) lose it.
///
/// ⚠️ **THE TAB COORDINATORS LIVE IN THE APP TARGET**, which has no unit-test
/// bundle: what each root's header wears is asked here, of the running app,
/// as a member (`-mock-auto-login`).
final class BalanceWhereSpentUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testTheBalanceStaysOnForYouAndProfileAndLeavesMessagesAndTheMap() {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login"]
        app.launch()
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 25), "no tab bar")

        // For You, the launch tab: where likes are spent the most.
        bar.buttons["For You"].firstMatch.tap()
        XCTAssertTrue(balance(in: app).waitForExistence(timeout: 25), "For You lost its balance")

        // Messages: `[bell] …` over the stacked search, no balance.
        bar.buttons["Messages"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.buttons["Notifications"].waitForExistence(timeout: 15),
                      "the Messages header has no bell")
        XCTAssertTrue(balance(in: app).waitForNonExistence(timeout: 8), "the Messages header wears the balance")

        // Explore, the map: `[bell] … [search]`, no balance.
        bar.buttons["Explore"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.buttons["Search"].waitForExistence(timeout: 15),
                      "the map's header has no search")
        XCTAssertTrue(app.navigationBars.buttons["Notifications"].exists, "the map's header has no bell")
        XCTAssertTrue(balance(in: app).waitForNonExistence(timeout: 8), "the map's header wears the balance")

        // The own profile: it lists posts with hearts, and it is the
        // wallet's door.
        bar.buttons["Profile"].firstMatch.tap()
        XCTAssertTrue(balance(in: app).waitForExistence(timeout: 15), "the own profile lost its balance")
        app.terminate()
    }

    /// The balance badge: its bar item reads "Likes balance" (a feature
    /// screen's own badge may surface its button's "Wallet, N likes…").
    private func balance(in app: XCUIApplication) -> XCUIElement {
        app.navigationBars.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Likes balance' OR label BEGINSWITH 'Wallet'")).firstMatch
    }
}
