import XCTest

/// A clip pauses under whatever covers it (#1970): the window hears every
/// presentation, and Shots' share reads 0 under a cover. This is the check
/// that the window still hears presentations — the unit test host never
/// completes one. Read through Shots' `-viewport-probe`
/// (`viewport;plays=…;covered=…`).
final class ScreenCoverUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func probe(in app: XCUIApplication) -> XCUIElement {
        app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'viewport;'")).firstMatch
    }

    /// Waits until the probe reads `plays`.
    private func expect(plays: Bool, in app: XCUIApplication, _ message: String) {
        let probe = probe(in: app)
        let predicate = NSPredicate(format: "identifier CONTAINS %@", "plays=\(plays ? 1 : 0);")
        let met = XCTNSPredicateExpectation(predicate: predicate, object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [met], timeout: 10), .completed,
                       "\(message) — probe: \(probe.exists ? probe.identifier : "absent")")
    }

    /// A guest likes the post on Shots: the fitted method list leaves the
    /// clip playing; the email form, at full height, pauses it; swiping the
    /// form away plays it again; closing the list keeps it playing.
    func testTheSignInFormPausesShotsAndItsSwipePlaysItAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["-guest", "-welcome-gift-reset", "-viewport-probe"]
        app.launch()

        let like = app.buttons["Like"]
        XCTAssertTrue(like.waitForExistence(timeout: 25), "Shots never showed its like button")
        expect(plays: true, in: app, "Shots does not play before anything covers it")

        like.tap()
        let list = app.navigationBars["Log in or sign up"]
        XCTAssertTrue(list.waitForExistence(timeout: 8), "like did not open the sign-in sheet")
        expect(plays: true, in: app, "the fitted method list paused the clip")

        let email = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'with email'")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 5), "the sheet offers no email sign-in")
        email.tap()
        let field = app.textFields["signup.email"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "the email form never rose")
        expect(plays: false, in: app, "the full-height form did not pause the clip")

        // The form's grabber, at its top, to the bottom of the screen.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(field.waitForNonExistence(timeout: 8), "the swipe did not take the form away")
        expect(plays: true, in: app, "the clip did not play again once the form went")

        list.buttons["auth.methods.close"].tap()
        XCTAssertTrue(list.waitForNonExistence(timeout: 8), "× did not close the sheet")
        expect(plays: true, in: app, "closing the list paused the clip")
    }

    /// The sound sheet, through the contract: collapsed, the clip plays;
    /// expanded, it pauses; collapsed again, it plays; closed, it plays.
    func testTheSoundSheetPausesShotsOnlyWhileExpanded() {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login", "-viewport-probe"]
        app.launch()
        XCTAssertTrue(app.buttons["Like"].waitForExistence(timeout: 25), "Shots never showed its rail")
        expect(plays: true, in: app, "Shots does not play before anything covers it")

        // The rail's record, at the foot of the rail.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.913, dy: 0.863)).tap()
        let close = app.buttons["sound.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8), "the record did not open the sound sheet")
        expect(plays: true, in: app, "the collapsed sound sheet paused the clip")

        // Up from the sheet's header, beside ✕: expanded.
        let grabber = close.coordinate(withNormalizedOffset: CGVector(dx: -1.5, dy: -0.3))
        grabber.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        expect(plays: false, in: app, "the expanded sound sheet did not pause the clip")

        // Down from the header to half: collapsed again.
        let top = close.coordinate(withNormalizedOffset: CGVector(dx: -1.5, dy: -0.3))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        expect(plays: true, in: app, "the clip did not play again once the sheet collapsed")

        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 8), "the sound sheet did not close")
        expect(plays: true, in: app, "closing the sound sheet paused the clip")
    }
}
