import XCTest

/// An unread tab says so to VoiceOver (#1196): the bar draws no count since
/// #1191 — the badge is part of the glyph's image — so the tab's VALUE
/// carries it. The shell lives in the app target, which has no unit-test
/// bundle: asked here, of the running app.
final class TabUnreadAccessibilityUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testAnUnreadTabCarriesItsValue() {
        let app = XCUIApplication()
        // The mock's inbox opens with unread conversations.
        app.launchArguments = ["-mock-auto-login", "-switch-tab", "1"]
        app.launch()

        let messages = app.tabBars.buttons["Messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 25), "no Messages tab")
        let unread = NSPredicate(format: "value == %@", "New messages")
        let carries = XCTNSPredicateExpectation(predicate: unread, object: messages)
        XCTAssertEqual(XCTWaiter().wait(for: [carries], timeout: 15), .completed,
                       "the unread Messages tab says nothing: \(String(describing: messages.value))")

        // Labels still drawn at launch (#694): the tab's title is its label.
        XCTAssertEqual(messages.label, "Messages")

        // Explore never counts anything.
        let explore = app.tabBars.buttons["Explore"]
        XCTAssertTrue(explore.exists)
        XCTAssertNotEqual(explore.value as? String, "New messages")
        XCTAssertNotEqual(explore.value as? String, "New posts")
        app.terminate()
    }
}
