import XCTest

/// The likes balance stands where likes are spent or earned, and leaves the
/// screens where it never moves (#2336, the owner 2026-11-12): Messages (no
/// heart, no spend, no claim) and the map (a tap opens the post, which wears
/// it) lose it — and since #2475 every profile, own or someone else's: the
/// wallet is Settings' (Wallet and Purchases).
///
/// ⚠️ **THE TAB COORDINATORS LIVE IN THE APP TARGET**, which has no unit-test
/// bundle: what each root's header wears is asked here, of the running app,
/// as a member (`-mock-auto-login`).
final class BalanceWhereSpentUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testTheBalanceLeavesMessagesTheMapAndTheProfile() {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login"]
        app.launch()
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 25), "no tab bar")

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

        // The own profile: `[bell] … [✎][⋯ ⚙]`, no balance (#2475).
        bar.buttons["Profile"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.buttons["Edit Profile"].waitForExistence(timeout: 15),
                      "the own profile's bar has no Edit")
        XCTAssertTrue(balance(in: app).waitForNonExistence(timeout: 8), "the own profile wears the balance")
        app.terminate()
    }

    /// The balance badge: its bar item reads "Likes balance" (a feature
    /// screen's own badge may surface its button's "Wallet, N likes…").
    private func balance(in app: XCUIApplication) -> XCUIElement {
        app.navigationBars.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Likes balance' OR label BEGINSWITH 'Wallet'")).firstMatch
    }
}
