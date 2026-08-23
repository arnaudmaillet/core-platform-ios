import XCTest

/// Drives a card's carousel onto its last clip and leaves it there.
///
/// Diagnostic, not an assertion: reading a defect out of the audit log needs the
/// defect to have happened, and this is the only way to make it happen without
/// taking the developer's mouse.
final class CardCarouselProbeUITests: XCTestCase {
    func testParkOnTheLastPageOfTheFirstCard() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mock-auto-login", "-open-foryou", "-rich-media", "-carousel-audit",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        Thread.sleep(forTimeInterval: 6)

        // The first card's media band, by proportion of the screen — the row
        // cell carries no identifier, and adding one to chase a defect would be
        // changing the thing under observation.
        func swipeCarousel() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.36))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.36))
            start.press(forDuration: 0.05, thenDragTo: end)
            Thread.sleep(forTimeInterval: 2)
        }

        for _ in 0..<3 { swipeCarousel() }
        Thread.sleep(forTimeInterval: 4)

        // ⚠️ THE PATH THE SWIPING PROBE NEVER TOOK — opening the post and
        // coming back. The acceleration was reported on the RETURN, and a probe
        // that only pages the card cannot see it: while the post is open the
        // card's player is parked and keeps RUNNING, so the picture the card
        // comes back to is not the picture it left.
        let media = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36))
        media.tap()
        Thread.sleep(forTimeInterval: 5)

        // Back out by the zoom dismissal: a downward drag from the media.
        let grabStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let grabEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        grabStart.press(forDuration: 0.1, thenDragTo: grabEnd)
        Thread.sleep(forTimeInterval: 10)
    }
}
