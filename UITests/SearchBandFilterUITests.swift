import XCTest

/// The filter still answers a finger, now that it lives inside the accessory.
///
/// ⚠️ **A UNIT TEST CANNOT ASK THIS.** `SearchFilterTrayTests` asserts the
/// button exists, carries the right label and sits after the strip — all true
/// of a control that draws perfectly and receives nothing. This repo has been
/// caught by exactly that shape twice: a bare `UIButton` used as a cell
/// accessory drew and never got taps, and a recogniser added to watch a control
/// silenced the control it was watching. The band is a view UIKit owns, inside
/// a container UIKit draws, with the strip's own touch probe running beside it
/// — so whether a tap reaches the filter is a question only a tap answers.
final class SearchBandFilterUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testTheFilterInTheBandOpensTheSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login", "-open-search",
                               "-search-query", "paris", "-search-submit"]
        app.launch()

        let filter = app.buttons["Filters"]
        XCTAssertTrue(filter.waitForExistence(timeout: 25),
                      "the filter is not in the accessibility tree at all")
        XCTAssertTrue(filter.isHittable,
                      "the filter draws but is not hittable — something is over it")
        filter.tap()

        // The sheet names the three dimensions; any one of them is proof it
        // came up.
        XCTAssertTrue(app.staticTexts["Rank by"].waitForExistence(timeout: 8),
                      "the tap did not reach the filter")
        app.terminate()
    }
}
