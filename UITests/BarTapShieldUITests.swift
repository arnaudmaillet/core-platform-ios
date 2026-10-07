import XCTest

/// #562: a tap beside the floating tab bar's capsule reaches nothing behind
/// it, while a pan that starts there still scrolls the content. A real finger
/// is the only honest driver: the shield is a gesture recogniser on the
/// window, and what it lets through is decided by how the finger moves.
final class BarTapShieldUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The Messages inbox: its rows run under the tab bar, and a row tapped
    /// opens a conversation — exactly what must not happen through the bar.
    private func launchInbox() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login", "-select-tab", "2"]
        app.launch()
        return app
    }

    /// The gap between the tab capsule and the "+" button, inside the bar's
    /// band, where the inbox's rows lie underneath.
    private func barGap(in app: XCUIApplication) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: 318.0 / 402, dy: 848.0 / 874))
    }

    func testATapBesideTheTabCapsuleOpensNothing() {
        let app = launchInbox()
        let firstRow = app.staticTexts["Kenji Tanaka"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "the inbox shows its first conversation")
        let before = firstRow.frame

        barGap(in: app).tap()
        sleep(2)

        XCTAssertTrue(firstRow.isHittable, "still on the inbox: no conversation opened through the bar")
        XCTAssertEqual(firstRow.frame.minY, before.minY, accuracy: 1, "nothing moved")
    }

    func testAPanFromTheTabBarBandStillScrolls() {
        let app = launchInbox()
        let firstRow = app.staticTexts["Kenji Tanaka"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20))
        let before = firstRow.frame.minY

        let start = barGap(in: app)
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 318.0 / 402, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)

        let moved = !firstRow.isHittable || firstRow.frame.minY < before - 100
        XCTAssertTrue(moved, "a pan starting in the tab bar's band scrolled the inbox "
            + "(row at \(before), now \(firstRow.frame.minY))")
    }
}
