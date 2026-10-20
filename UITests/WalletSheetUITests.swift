import XCTest

/// The Rewards sheet (#1494) through real taps and drags: one sheet with two
/// heights, opening expanded, the Claim as its toolbar's trailing item, three
/// doors under the balance — the Shop, Settled and Activity — and the active
/// stakes below.
///
/// ⚠️ **THE SHEET LIVES IN THE APP TARGET**, which has no unit-test bundle:
/// `WalletSheetViewController` is the shell's (it joins the wallet store, the
/// Feed feature's posts and the Maps feature's shop). So what the sheet SHOWS
/// is asked here, of the running app — the Shop list's own geometry and edge
/// effect are unit-tested in `MapsTests/CountryShopViewControllerTests`.
final class WalletSheetUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// How far the sheet's top moves between its two heights, at least: on
    /// the iPhone SE the small height is most of the screen.
    private static let heightStep: CGFloat = 40

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login", "-open-wallet", "-wallet-how-it-works-seen"] + extra
        app.launch()
        return app
    }

    /// Collapsed: `[?] Rewards [✕]`, one Claim at the toolbar's trailing
    /// end, the three doors — no Shop item in the bar. The Shop door opens
    /// the Shop.
    func testCollapsedRewardsAndTheShopDoorOpensTheShop() {
        let app = launch(["-wallet-sheet-small"])

        let claim = app.buttons["wallet.claim"]
        XCTAssertTrue(claim.waitForExistence(timeout: 25), "the Wallet has no Claim")
        XCTAssertEqual(app.buttons.matching(identifier: "wallet.claim").count, 1)
        XCTAssertTrue(app.buttons["wallet.help"].exists, "the Wallet has no How it works item")
        XCTAssertTrue(app.buttons["wallet.close"].exists, "the Wallet has no close item")
        XCTAssertLessThan(app.buttons["wallet.help"].frame.minX, app.buttons["wallet.close"].frame.minX)
        XCTAssertFalse(app.buttons["wallet.shop"].exists, "the bar still carries a Shop item")
        XCTAssertFalse(app.descendants(matching: .any)["wallet.hub.open"].exists, "the Wallet row is still there")

        let shopDoor = app.buttons["wallet.gems.shop"]
        let settled = app.buttons["wallet.settled"]
        let activity = app.buttons["wallet.activity"]
        for door in [shopDoor, settled, activity] {
            XCTAssertTrue(door.isHittable, "a door is missing at the small height")
        }
        // The Shop is the large door, and the Claim is under the doors.
        XCTAssertGreaterThan(shopDoor.frame.width, settled.frame.width * 1.5)
        XCTAssertGreaterThan(claim.frame.minY, shopDoor.frame.maxY, "the Claim is not the toolbar's")
        XCTAssertGreaterThan(claim.frame.midX, app.windows.firstMatch.frame.midX, "the Claim is not the toolbar's trailing item")
        XCTAssertGreaterThan(shopDoor.frame.minY, app.windows.firstMatch.frame.height / 3,
                             "the sheet did not collapse")

        // The Shop door → the Shop's own screen: the sheet comes down, the
        // Shop is pushed under it.
        shopDoor.tap()
        let shop = app.navigationBars["Shop"]
        XCTAssertTrue(shop.waitForExistence(timeout: 8), "the Shop door did not open the Shop")
        XCTAssertTrue(claim.waitForNonExistence(timeout: 8), "the Wallet stayed over the Shop")
        shop.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(shop.waitForNonExistence(timeout: 8), "back did not leave the Shop")
        app.terminate()
    }

    /// Pulled up, the collapsed sheet grows to large without moving the top
    /// in it; the active stakes are below it, and the Claim stays in the
    /// toolbar.
    func testPullingUpGrowsTheSheetAndTheClaimStays() {
        let app = launch(["-wallet-claim-ready", "-wallet-sheet-small"])

        let claim = app.buttons["wallet.claim"]
        XCTAssertTrue(claim.waitForExistence(timeout: 25))
        let shopDoor = app.buttons["wallet.gems.shop"]
        let close = app.buttons["wallet.close"]
        let smallTop = close.frame.minY
        // Measured against the sheet's own top (its list starts there), not
        // the bar's items, which UIKit seats a little differently at the two
        // heights — and in the sheet's width: iOS 26 draws the small sheet
        // inset and a little smaller (≈ 96 %), the large one full size.
        let list = app.collectionViews.firstMatch
        let place = { (shopDoor.frame.minY - list.frame.minY) / list.frame.width }
        let smallPlace = place()

        // Grown by its bar, as by the grabber: a swipe on the list keeps
        // scrolling once the sheet has grown, on the SE's short screen.
        let bar = app.navigationBars["Rewards"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -6)))
        let grown = NSPredicate { _, _ in close.frame.minY < smallTop - Self.heightStep }
        wait(for: [expectation(for: grown, evaluatedWith: nil)], timeout: 8)
        // The sheet springs into place: read once it has settled.
        var settled = place()
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = place()
            if abs(now - settled) < 0.001 { break }
            settled = now
        }
        XCTAssertEqual(settled, smallPlace, accuracy: 0.005, "growing the sheet moved the top in it")
        let active = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Active stakes'"))
        XCTAssertGreaterThan(active.count, 0, "the large Wallet has no Active stakes")

        // The Claim is the toolbar's: still there, and it claims.
        XCTAssertTrue(claim.isHittable)
        let before = claim.label
        claim.tap()
        let claimed = NSPredicate { _, _ in claim.label != before }
        wait(for: [expectation(for: claimed, evaluatedWith: nil)], timeout: 10)
        app.terminate()
    }

    /// Expanded as it opens; the Activity and Settled doors push their
    /// screens in the sheet — the filter in the bar, no title — and back
    /// returns to Rewards; drag down goes large → small → dismissed.
    func testTheDoorsPushAndDragDownStepsDown() {
        let app = launch()

        let close = app.buttons["wallet.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 25))
        let largeTop = close.frame.minY
        XCTAssertLessThan(largeTop, app.windows.firstMatch.frame.height / 4, "Rewards did not open expanded")
        app.buttons["wallet.activity"].tap()
        let gems = app.segmentedControls.buttons["Gems"]
        XCTAssertTrue(gems.waitForExistence(timeout: 8), "the Activity door did not push the history")
        XCTAssertFalse(app.navigationBars["Wallet and Purchases"].exists, "the history kept its title")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        let rewards = app.navigationBars["Rewards"]
        XCTAssertTrue(rewards.waitForExistence(timeout: 8), "back did not return to Rewards")

        app.buttons["wallet.settled"].tap()
        let settled = app.segmentedControls.buttons["Settled"]
        XCTAssertTrue(settled.waitForExistence(timeout: 8), "the Settled door did not push the stakes")
        XCTAssertTrue(settled.isSelected, "the Settled door did not open on Settled")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(rewards.waitForExistence(timeout: 8), "back did not return to Rewards")
        let wallet = rewards

        // Large → small, the bar dragged down.
        wallet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: wallet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 6)))
        let small = NSPredicate { _, _ in close.exists && close.frame.minY > largeTop + Self.heightStep }
        wait(for: [expectation(for: small, evaluatedWith: nil)], timeout: 8)

        // Small → dismissed.
        wallet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: wallet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 12)))
        XCTAssertTrue(close.waitForNonExistence(timeout: 8), "dragging the small Wallet down did not dismiss it")
        app.terminate()
    }
}
