import XCTest

/// The CARD ⇄ full-screen family, opened by real fingers on every surface
/// that draws one — the question the matrix suite left half-answered: its
/// real taps landed on the feed's FIRST card (text, so the reveal family),
/// while the media hero's opening stayed scripted. Here the finger does the
/// opening too, on a card on a pushed profile. (For You's Activity list and
/// Media grid went with the tab, #2453.)
final class HeroCardUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The first cell whose images say "this card carries media": every card
    /// has an avatar, so one image is furniture — the media is the LARGE one.
    /// Returns the media image element, or nil after `limit` cells.
    private func mediaImage(in app: XCUIApplication, limit: Int = 8) -> XCUIElement? {
        let cells = app.collectionViews.firstMatch.cells
        for index in 0..<min(limit, cells.count) {
            let cell = cells.element(boundBy: index)
            guard cell.exists else { continue }
            let images = cell.images
            for imageIndex in 0..<images.count {
                let image = images.element(boundBy: imageIndex)
                let frame = image.frame
                if frame.height > 120, frame.width > 200, image.isHittable {
                    return image
                }
            }
        }
        return nil
    }

    // MARK: - A card on a pushed profile

    /// The other surface that draws cards: a profile's gallery. Same seam
    /// (`SnapFeedHeroOrigin`, deliberately without repoint), a real finger on
    /// a row, and the same checklist — pinned in-sim because the election
    /// tests cover the wiring but no screen ever ran it under a finger.
    func testAProfileCardOpensAndReturns() throws {
        let app = launchHeroApp(arguments: ["-open-profile", "prof-0"])
        waitForHeroSettle(in: app, after: 0)

        // The profile's gallery collection arrives once the profile loaded.
        let row = app.collectionViews.firstMatch.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 25),
                      "the profile gallery never showed a row")
        // Rows near the header can sit under the top dead band; nudge the
        // gallery up so the tapped row is unambiguously hittable.
        if !row.isHittable { app.swipeUp() }
        let target = app.collectionViews.firstMatch.cells.firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5) && target.isHittable,
                      "no hittable gallery row on the profile")

        let before = heroProbe(in: app)?.sequence ?? 0
        target.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10),
                      "tapping the profile card opened nothing")
        let opened = waitForHeroSettle(in: app, after: before,
                                       "the profile-card open never settled")
        assertHeroResidueClear(opened, "after opening from a profile card")
        attachHeroEvidence(app, name: "s07-profile-card-open")

        let beforeReturn = opened?.sequence ?? 0
        app.navigationBars.buttons.firstMatch.tap()
        let returned = waitForHeroSettle(in: app, after: beforeReturn,
                                         "the profile-card return never settled")
        assertHeroResidueClear(returned, "after returning to the profile")
        attachHeroEvidence(app, name: "s07-profile-card-returned")
    }
}
