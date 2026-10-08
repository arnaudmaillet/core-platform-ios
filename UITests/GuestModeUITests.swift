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

    /// The guest bar holds only what a guest can use (#626): Explore, For You,
    /// Settings and a "Sign in" bubble — no Messages. Settings is the tab's
    /// root, with the bar still under it. Signing in turns the bar back into
    /// the member's, without a tap.
    func testTheGuestBarHoldsOnlyWhatAGuestCanUseUntilTheySignIn() {
        let app = launch(["-guest-sign-in-after", "12"])
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 25), "no tab bar")
        let settings = bar.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the guest bar has no Settings")
        XCTAssertTrue(bar.buttons["Sign in"].exists, "the guest bar has no Sign in bubble")
        XCTAssertFalse(bar.buttons["Messages"].exists, "Messages is in the guest bar")

        settings.tap()
        XCTAssertTrue(app.staticTexts["Playback and Sound"].waitForExistence(timeout: 8),
                      "Settings is not the tab's root")
        XCTAssertTrue(bar.isHittable, "the bar left with the Settings root")

        XCTAssertTrue(bar.buttons["Messages"].waitForExistence(timeout: 25), "signing in did not bring Messages back")
        XCTAssertTrue(bar.buttons["Profile"].exists, "the member bar has no Profile")
        XCTAssertTrue(bar.buttons["Create"].exists,
                      "the member bar has no \"+\": \(bar.buttons.allElementsBoundByIndex.map { $0.label })")
        XCTAssertFalse(bar.buttons["Settings"].exists, "the guest's Settings tab outlived the sign-in")
    }

    /// One tap on the guest's bubble opens the login sheet — no create menu.
    func testTheSignInBubbleOpensTheSheetInOneTap() {
        let app = launch([])
        let signIn = app.tabBars.buttons["Sign in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 25), "the guest bar has no Sign in bubble")
        signIn.tap()
        let email = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'with email'")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 8), "the bubble did not open the login sheet")
        XCTAssertFalse(app.buttons["Text Post"].exists, "the create menu opened for a guest")
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
    /// rail's like stakes a point), signs in from the sheet with a code sent
    /// to the mock's demo address — and is still on that post, with the like
    /// landed.
    func testAGuestsLikeLandsAfterSigningInFromTheSheet() {
        let app = launch(["-open-post", "post-0001"])
        let (like, before, prompt) = likeAsGuest(in: app)

        continueWithEmail("demo@example.com", code: "123456", in: app)

        XCTAssertTrue(prompt.waitForNonExistence(timeout: 15), "signing in did not close the sheet")
        assertLikeLanded(like, before: before, in: app)
    }

    /// A new address signs up from the sheet — code, birthday, consent,
    /// username — and the like the guest started lands on the post they were
    /// reading (#444).
    func testAGuestSignsUpByCodeAndTheirLikeLands() {
        let app = launch(["-open-post", "post-0001"])
        let (like, before, prompt) = likeAsGuest(in: app)

        continueWithEmail("new.guest@example.com", code: "123456", in: app)
        let birthday = app.buttons["Continue"]
        XCTAssertTrue(app.staticTexts["When\u{2019}s Your Birthday?"].waitForExistence(timeout: 10), "no birthday step")
        birthday.tap()
        let agree = app.buttons["Agree and Continue"]
        XCTAssertTrue(agree.waitForExistence(timeout: 8), "no consent step")
        agree.tap()
        let handle = app.textFields["signup.handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 10), "no username step")
        handle.typeText("new.guest")
        XCTAssertTrue(staticText(beginningWith: "@new.guest is available", in: app).waitForExistence(timeout: 8),
                      "the username was never checked")
        app.buttons["Create Account"].tap()

        XCTAssertTrue(prompt.waitForNonExistence(timeout: 15), "signing up did not close the sheet")
        assertLikeLanded(like, before: before, in: app)
    }

    // MARK: Steps

    /// Opens the post's sign-up sheet by liking it as a guest: the like
    /// button, its value before, and the sheet's headline.
    private func likeAsGuest(in app: XCUIApplication) -> (XCUIElement, String?, XCUIElement) {
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
        return (like, before, prompt)
    }

    /// "Continue with email": the address, then the six digits (the step
    /// submits on the sixth). A method is a list row, so it is matched at any
    /// type.
    private func continueWithEmail(_ address: String, code: String, in app: XCUIApplication) {
        let email = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'with email'")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 5), "the sheet offers no email sign-in")
        email.tap()
        let field = app.textFields["signup.email"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "the email step never appeared")
        // Return is the step's Go: it sends the code.
        field.typeText("\(address)\n")
        let codeField = app.textFields["signup.code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 10), "the code step never appeared")
        codeField.typeText(code)
    }

    /// The replayed like stakes one more point on the post, and the viewer is
    /// still on it, pushed where they were: its rail and its back button.
    private func assertLikeLanded(_ like: XCUIElement, before: String?, in app: XCUIApplication) {
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before ?? ""), object: like)
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 10), .completed, "the like did not land")
        XCTAssertTrue(like.exists, "signing in moved the viewer off the post")
        XCTAssertTrue(app.buttons["BackButton"].exists, "signing in reset the post's stack")
    }
}
