import XCTest

/// The points sheet's bar and the Shop it opens, through real taps.
///
/// ⚠️ **THE SHEET LIVES IN THE APP TARGET**, which has no unit-test bundle:
/// `WalletClaimViewController` is the shell's (it joins the wallet store, the
/// Feed feature's posts and the Maps feature's shop). So what the sheet SHOWS
/// is asked here, of the running app — the Shop list's own geometry and edge
/// effect are unit-tested in `MapsTests/CountryShopViewControllerTests`.
final class WalletSheetUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testThePointsSheetBarOpensTheShopOverItAndBothClose() {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login", "-open-wallet"]
        app.launch()

        // `[storefront Shop] ······ [✕]` — the bar's two items.
        let shop = app.buttons["wallet.shop"]
        XCTAssertTrue(shop.waitForExistence(timeout: 25), "the points sheet has no Shop item")
        XCTAssertEqual(shop.label, "Shop")
        let close = app.buttons["wallet.close"]
        XCTAssertTrue(close.exists, "the points sheet has no close item")
        XCTAssertGreaterThan(shop.frame.midY, 0)
        XCTAssertLessThan(shop.frame.minX, close.frame.minX, "Shop is not the LEADING item")

        // No Countries card: the bar's Shop replaced it.
        let countriesCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Countries'"))
        XCTAssertEqual(countriesCard.count, 0, "the Countries card is still on the sheet")

        // Scrolled, nothing collapses into compact balances under the bar
        // (the old `WalletCompactBar` read "N points, M gems").
        let list = app.collectionViews.firstMatch
        list.swipeUp()
        list.swipeUp()
        let compact = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES '^[0-9]+ points, [0-9]+ gems$'"))
        XCTAssertEqual(compact.count, 0, "compact counters appeared on scroll")

        // Shop → the shop sheet, over the points sheet.
        XCTAssertTrue(shop.isHittable)
        shop.tap()
        let search = app.searchFields["Search countries"]
        XCTAssertTrue(search.waitForExistence(timeout: 8), "the Shop item did not present the shop")

        // A plain list: a country's row spans its list's full width.
        // A country row reads "<name>, rank <n>, …" (whichever is first).
        let row = app.cells.matching(NSPredicate(format: "label CONTAINS ', rank '")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no country row in the shop")
        let listFrame = app.collectionViews
            .containing(NSPredicate(format: "label CONTAINS ', rank '")).firstMatch.frame
        XCTAssertEqual(row.frame.minX, listFrame.minX, accuracy: 1, "the row starts inside a card")
        XCTAssertEqual(row.frame.width, listFrame.width, accuracy: 1, "the row is narrower than the list")

        // Closing the shop comes back to the points sheet.
        app.buttons["shop.close"].tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 8), "the shop did not close")
        XCTAssertTrue(shop.waitForExistence(timeout: 5), "closing the shop also closed the points sheet")

        // And the points sheet's own close takes it down.
        close.tap()
        XCTAssertTrue(shop.waitForNonExistence(timeout: 8), "the close item did not dismiss the points sheet")
        app.terminate()
    }
}
