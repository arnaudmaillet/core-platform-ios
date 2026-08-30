import XCTest

/// Case B, end to end (plan IDs S09, D08, D09): the cluster feed with its
/// gallery invisibly beneath — the vertical grab morphs into the gallery, a
/// tile re-opens a feed, and the horizontal swipe escapes PAST the gallery to
/// the map. The stack choreography under this (reorder-then-single-pop,
/// deferred reinsertion) is where a leak or a stranded screen hides best.
final class ClusterGalleryUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchOnClusterFeed() -> XCUIApplication {
        launchHeroApp(arguments: [
            "-maps-mock-semantic-clusters", "-maps-open-first-media-cluster",
        ])
    }

    /// The whole loop: feed → (vertical grab) gallery → (tile tap) feed →
    /// (horizontal swipe) map — the census read at every stop, evidence at
    /// every stop. One test rather than four, because the loop IS the
    /// feature: each leg's teardown is the next leg's precondition.
    func testTheCaseBLoopEndsOnTheMapWithNothingAlive() {
        let app = launchOnClusterFeed()
        let opened = waitForHeroSettle(in: app, after: 0, timeout: 40,
                                       "the cluster feed never settled")
        assertHeroResidueClear(opened, "after the cluster feed opened")
        attachHeroEvidence(app, name: "s09-cluster-feed")

        // Leg 1 — vertical grab lands on the GALLERY beneath.
        var before = opened?.sequence ?? 0
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05,
                   thenDragTo: app.windows.firstMatch
                       .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                   withVelocity: 1400, thenHoldForDuration: 0)
        let onGallery = waitForHeroSettle(in: app, after: before, timeout: 30,
                                          "the vertical grab never settled")
        assertHeroResidueClear(onGallery, "after the grab to the gallery")
        let galleryGrid = app.collectionViews.firstMatch
        XCTAssertTrue(galleryGrid.waitForExistence(timeout: 10),
                      "no gallery grid after the vertical grab")
        attachHeroEvidence(app, name: "d08-landed-on-gallery")

        // Leg 2 — a gallery tile re-opens a feed.
        before = heroProbe(in: app)?.sequence ?? 0
        let tile = galleryGrid.cells.firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "the gallery showed no tile")
        tile.tap()
        let reopened = waitForHeroSettle(in: app, after: before, timeout: 30,
                                         "the tile re-open never settled")
        assertHeroResidueClear(reopened, "after re-opening from the gallery")
        attachHeroEvidence(app, name: "d08-reopened-feed")

        // Leg 3 — the horizontal swipe escapes PAST the gallery to the map.
        before = reopened?.sequence ?? 0
        app.swipeRight()
        let onMap = waitForHeroSettle(in: app, after: before, timeout: 30,
                                      "the escape never settled")
        assertHeroResidueClear(onMap, "after the horizontal escape")
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10),
                      "the escape did not land on the map")
        attachHeroEvidence(app, name: "d09-escaped-to-map")
    }

    /// The abandoned escape: a short horizontal drag, released — the feed
    /// stays, and (the deferred-reinsertion contract) the NEXT vertical grab
    /// still lands on the gallery, which was dropped at swipe-begin and must
    /// have been put back on the cancel.
    func testAnAbandonedEscapeStillLandsTheNextGrabOnTheGallery() {
        let app = launchOnClusterFeed()
        let opened = waitForHeroSettle(in: app, after: 0, timeout: 40)
        assertHeroResidueClear(opened, "after the cluster feed opened")

        // The abandoned escape.
        var before = opened?.sequence ?? 0
        let start = app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.05,
                    thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0)),
                    withVelocity: 200, thenHoldForDuration: 0.15)
        let stayed = waitForHeroSettle(in: app, after: before, timeout: 30,
                                       "the abandoned escape never settled")
        assertHeroResidueClear(stayed, "after abandoning the escape")
        attachHeroEvidence(app, name: "d09-escape-abandoned")

        // The gallery is back beneath: the vertical grab finds it.
        before = heroProbe(in: app)?.sequence ?? 0
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05,
                   thenDragTo: app.windows.firstMatch
                       .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                   withVelocity: 1400, thenHoldForDuration: 0)
        let onGallery = waitForHeroSettle(in: app, after: before, timeout: 30,
                                          "the post-cancel grab never settled")
        assertHeroResidueClear(onGallery, "after grabbing to the reinserted gallery")
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10),
                      "the reinserted gallery was not there to land on — "
                      + "the cancel path lost it (the deferred-reinsertion contract)")
        attachHeroEvidence(app, name: "d09-grab-after-abandon")
    }
}
