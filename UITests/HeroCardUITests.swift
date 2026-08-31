import XCTest

/// The CARD ⇄ full-screen family, opened by real fingers on every surface
/// that draws one — the question the matrix suite left half-answered: its
/// real taps landed on the feed's FIRST card (text, so the reveal family),
/// while the media hero's opening stayed scripted. Here the finger does the
/// opening too: a media card's picture on the Activity list, a tile on the
/// Media grid, and a card on a pushed profile.
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

    // MARK: - A media card's picture, tapped for real (Activity list)

    /// The tap lands on the media area — the carousel's own "open this post"
    /// tap — so the flight is the `.listMedia` hero: the row's picture flies,
    /// not the whole card. Home by real grab; the census clean both ways.
    func testAMediaCardsPictureFliesUnderARealFinger() throws {
        let app = launchHeroApp(arguments: ["-select-tab", "1"])
        waitForHeroSettle(in: app, after: 0)
        XCTAssertTrue(app.collectionViews.firstMatch.cells.firstMatch
            .waitForExistence(timeout: 20), "the card list never showed")

        // Media cards sit below the first (text) cards on the mock corpus;
        // scroll until one shows a tappable picture.
        var media = mediaImage(in: app)
        var scrolls = 0
        while media == nil, scrolls < 4 {
            app.swipeUp()
            scrolls += 1
            media = mediaImage(in: app)
        }
        let picture = try XCTUnwrap(media, "no media card within \(4) screens of cards")

        let before = heroProbe(in: app)?.sequence ?? 0
        picture.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10),
                      "tapping the card's picture opened nothing")
        let opened = waitForHeroSettle(in: app, after: before,
                                       "the card-media open never settled")
        assertHeroResidueClear(opened, "after opening from a card's picture")
        attachHeroEvidence(app, name: "s03-card-media-open")

        let beforeReturn = opened?.sequence ?? 0
        app.swipeRight()
        let returned = waitForHeroSettle(in: app, after: beforeReturn,
                                         "the return to the card never settled")
        assertHeroResidueClear(returned, "after flying home to the card")
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5),
                      "the card list did not come back")
        attachHeroEvidence(app, name: "s03-card-media-returned")
    }

    // MARK: - A tile on the Media grid, tapped for real

    /// The mosaic: switch the pager to Discover — the header tabs map onto
    /// `ForYouPagerView.pageOrder`, and Discover IS the `.media` grid page
    /// (Following is the `.activity` card list). A tile is a rect whatever
    /// the post, so EVERY tile flies; tap one, come home by the back button,
    /// twice, because the second open is where reuse bugs live.
    func testATileOnTheMediaGridFliesUnderARealFinger() throws {
        let app = launchHeroApp(arguments: ["-select-tab", "1"])
        waitForHeroSettle(in: app, after: 0)

        let mediaTab = app.staticTexts["Discover"].firstMatch
        XCTAssertTrue(mediaTab.waitForExistence(timeout: 15),
                      "no Discover tab in the For You header")
        mediaTab.tap()

        for round in 1...2 {
            let tile = app.collectionViews.firstMatch.cells.firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 20),
                          "round \(round): the media grid never showed a tile")
            guard tile.isHittable else {
                app.swipeDown()
                continue
            }
            let before = heroProbe(in: app)?.sequence ?? 0
            tile.tap()
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10),
                          "round \(round): the tile tap opened nothing")
            let opened = waitForHeroSettle(in: app, after: before,
                                           "round \(round): the tile open never settled")
            assertHeroResidueClear(opened, "round \(round): after the tile open")
            attachHeroEvidence(app, name: "s01-grid-tile-open-round\(round)")

            let beforeReturn = opened?.sequence ?? 0
            app.navigationBars.buttons.firstMatch.tap()
            let returned = waitForHeroSettle(in: app, after: beforeReturn,
                                             "round \(round): the tile return never settled")
            assertHeroResidueClear(returned, "round \(round): after the tile return")
            attachHeroEvidence(app, name: "s01-grid-tile-returned-round\(round)")
        }
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
