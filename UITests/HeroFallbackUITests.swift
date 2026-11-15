import XCTest

/// The degradations, exercised end-to-end (plan IDs S04, S08, S10–S12, D11):
/// every way a post opens when there is nothing to fly, or the thing to fly
/// is late, failing, or gone — each must land somewhere sane and leave the
/// same nothing behind as the happy path.
final class HeroFallbackUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - S04/S08: the reveal family, via the Maps text pin

    /// A text pin opens as a REVEAL (the marker's disc is the window) — the
    /// scripted opener drives it, the swipe closes it, and the checklist is
    /// the same one the hero owes. This is the fallback-presentation family's
    /// end-to-end: no card, no flight, still zero residue.
    func testATextPinRevealOpensAndClosesClean() {
        let app = launchHeroApp(arguments: ["-maps-open-first-text-pin"])
        let opened = waitForHeroSettle(in: app, after: 0, "the text-pin reveal never settled")
        assertHeroResidueClear(opened, "after the reveal opened")
        attachHeroEvidence(app, name: "s04-text-reveal-open")

        let before = opened?.sequence ?? 0
        app.swipeRight()
        let returned = waitForHeroSettle(in: app, after: before, "the reveal close never settled")
        assertHeroResidueClear(returned, "after the reveal closed")
        attachHeroEvidence(app, name: "s04-text-reveal-closed")
    }

    /// The media pin flies a PinCardView — the Maps side of the shared
    /// machinery, smoke-tested through the same checklist.
    func testAMediaPinFliesAndReturns() {
        let app = launchHeroApp(arguments: ["-maps-open-first-pin", "-maps-force-video"])
        let opened = waitForHeroSettle(in: app, after: 0, "the pin flight never settled")
        assertHeroResidueClear(opened, "after the pin opened")
        attachHeroEvidence(app, name: "s08-pin-open")

        let before = opened?.sequence ?? 0
        app.navigationBars.buttons.firstMatch.tap()
        let returned = waitForHeroSettle(in: app, after: before, "the pin return never settled")
        assertHeroResidueClear(returned, "after the pin return")
        attachHeroEvidence(app, name: "s08-pin-returned")
    }
}
