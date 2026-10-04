import XCTest

/// Guest mode, end to end, through real taps (`dev/GUEST_MODE_REPORT.md` §6.7).
///
/// A `-guest` run starts signed out against a mock whose edge refuses a
/// guest's writes (`MockEdgePolicy`), and takes its `-open-*` deep links as
/// that guest. What these assert is what a unit test cannot reach: that the
/// gate's sheet is the one that appears, that closing it leaves the guest
/// where they were, and that signing in from it lands the action they started
/// without moving them.
final class GuestModeUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-guest", "-welcome-gift-reset"] + arguments
        app.launch()
        return app
    }

    private func staticText(beginningWith prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// Decision 8: no nudges. A guest scrolls For You and nothing asks them
    /// to sign up until they try to do something.
    func testAGuestBrowsesForYouWithoutBeingAsked() {
        let app = launch(["-open-foryou"])
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 25), "For You never showed a list")
        list.swipeUp()
        list.swipeUp()
        list.swipeDown()
        XCTAssertFalse(
            staticText(beginningWith: "Sign up", in: app).waitForExistence(timeout: 2),
            "browsing asked the guest to sign up"
        )
        XCTAssertTrue(app.tabBars.buttons["For You"].exists, "the guest left For You")
    }

    /// A gated action asks, titled for that action; closing the sheet leaves
    /// the guest on the screen they were reading.
    func testClosingTheSignUpSheetLeavesTheGuestWhereTheyWere() {
        let app = launch(["-open-profile", "prof-1"])
        let follow = app.buttons["Follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 25), "the profile has no Follow button")
        follow.tap()

        let prompt = staticText(beginningWith: "Sign up to follow", in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8), "Follow did not ask the guest to sign up")
        // The bar's system close item, labelled "close".
        app.buttons.matching(NSPredicate(format: "label ==[c] 'close'")).firstMatch.tap()

        XCTAssertTrue(prompt.waitForNonExistence(timeout: 8), "the sign-up sheet did not close")
        XCTAssertTrue(follow.waitForExistence(timeout: 5), "closing the sheet moved the guest off the profile")
    }

    /// The whole loop: a guest reads a post and its comments, likes it (the
    /// rail's like stakes a point), signs in from the sheet with the mock's
    /// credentials — and is still on that post, with the like landed.
    func testAGuestsLikeLandsAfterSigningInFromTheSheet() {
        let app = launch(["-open-post", "post-0001"])
        let like = app.buttons["Boost post"]
        XCTAssertTrue(like.waitForExistence(timeout: 25), "the post never showed its like button")
        // The comments are readable; writing one is what needs an account.
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "placeholderValue == 'Sign up to comment' OR label == 'Sign up to comment'"))
                .firstMatch.waitForExistence(timeout: 5),
            "the comment field does not invite the guest to sign up"
        )
        let before = like.value as? String

        like.tap()
        // The welcome gift is named on a like (report §3.2).
        let prompt = staticText(beginningWith: "Sign up to use your", in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8), "like did not ask the guest to sign up")

        // "Login with Email" today, "Continue with email" once #467 lands. A
        // method is a list row, so it is matched at any type.
        let email = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'with email'")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 5), "the sheet offers no email sign-in")
        email.tap()

        let identifier = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Email'")).firstMatch
        XCTAssertTrue(identifier.waitForExistence(timeout: 8), "the email screen never appeared")
        identifier.tap()
        identifier.typeText("demo")
        let password = app.secureTextFields.matching(NSPredicate(format: "placeholderValue == 'Password'")).firstMatch
        password.tap()
        // Return is the form's Go: it submits.
        password.typeText("password123\n")

        XCTAssertTrue(prompt.waitForNonExistence(timeout: 15), "signing in did not close the sheet")
        // The replayed like stakes one more point on the post.
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before ?? ""), object: like)
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 10), .completed, "the like did not land")
        // iOS offers to save the password over the app (an AutoFill panel in
        // SpringBoard's process, not the app's): decline it when it shows.
        let notNow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
        // Still on the post, pushed where it was: its rail and its back button.
        XCTAssertTrue(like.exists, "signing in moved the viewer off the post")
        XCTAssertTrue(app.buttons["BackButton"].exists, "signing in reset the post's stack")
    }
}
