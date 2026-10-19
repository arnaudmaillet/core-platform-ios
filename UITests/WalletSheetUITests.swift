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

    func testThePointsSheetBarOpensTheShopScreen() {
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
            .matching(NSPredicate(format: "label MATCHES '^[0-9]+ (points|likes), [0-9]+ gems$'"))
        XCTAssertEqual(compact.count, 0, "compact counters appeared on scroll")

        // Shop → the Shop's own screen (2026-10-13: pushed, not a sheet):
        // the points sheet comes down, and the Shop is pushed under it.
        XCTAssertTrue(shop.isHittable)
        shop.tap()
        let title = app.navigationBars["Shop"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "the Shop item did not open the Shop")
        XCTAssertTrue(shop.waitForNonExistence(timeout: 8), "the points sheet stayed over the Shop")
        XCTAssertFalse(app.buttons["shop.close"].exists, "a pushed Shop has no close button")

        // Back comes back to where the sheet was opened.
        title.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 8), "back did not leave the Shop")
        app.terminate()
    }
}
