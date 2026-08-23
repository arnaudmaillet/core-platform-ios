import XCTest

/// The retention window, driven by real swipes.
///
/// ## Why this target exists at all
///
/// Everything else in this feature is asserted in a unit test, which drives the
/// page change through `setPage` — the same call a swipe ends in, but not the
/// swipe. What no unit test can reach is the gesture itself: the pan the
/// carousel recognises, the deceleration, the page it settles on.
///
/// It was reached until now by injecting `CGEvent`s into the host's window
/// server, which moves the developer's actual mouse pointer — a tool that
/// cannot run unattended, cannot run in CI, and takes the machine away from
/// whoever is using it. XCUITest delivers the same gesture through the
/// automation harness, inside the simulator, touching nothing outside it.
///
/// ## What is asserted
///
/// Not pixels. "The clip kept its player" and "the clip was decoded again" look
/// identical in a screenshot; the difference is a cut, which is invisible in any
/// single frame. The cell publishes its retention state as an accessibility
/// identifier (see `publishRetentionProbe`) and these read it — the probe is the
/// thing that can be wrong, so it is the thing worth asserting.
final class CarouselRetentionUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private struct Probe {
        let page: Int, pages: Int, clips: Int, kept: Int, players: Int, capacity: Int

        /// Parses `carousel;page=1;pages=4;clips=2;kept=2;players=2;capacity=6`.
        init?(_ identifier: String) {
            let fields = identifier.split(separator: ";")
            guard fields.first == "carousel" else { return nil }
            var values: [String: Int] = [:]
            for field in fields.dropFirst() {
                let pair = field.split(separator: "=")
                guard pair.count == 2, let value = Int(pair[1]) else { return nil }
                values[String(pair[0])] = value
            }
            guard let page = values["page"], let pages = values["pages"],
                  let clips = values["clips"], let kept = values["kept"],
                  let players = values["players"],
                  let capacity = values["capacity"] else { return nil }
            (self.page, self.pages, self.clips) = (page, pages, clips)
            (self.kept, self.players, self.capacity) = (kept, players, capacity)
        }
    }

    private func launch(startIndex: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mock-auto-login", "-open-feed", "-rich-media",
            "-snap-start-index", "\(startIndex)",
        ]
        app.launch()
        return app
    }

    /// The probe of whatever collection is on screen, once one appears.
    private func probe(in app: XCUIApplication, timeout: TimeInterval = 12) -> Probe? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'carousel;'")
        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        guard element.waitForExistence(timeout: timeout) else { return nil }
        return Probe(element.identifier)
    }

    /// Prints the accessibility tree of a known collection post.
    ///
    /// Kept because "the probe is missing" and "the probe is there and my query
    /// does not match it" are indistinguishable from a failing assertion, and
    /// guessing between them costs more than one run that simply looks.
    func testDumpTheTreeOfACollectionPost() throws {
        let app = launch(startIndex: 4)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        Thread.sleep(forTimeInterval: 6)
        let tree = app.debugDescription
        print("=== PROBE PRESENT: \(tree.contains("carousel;"))")
        print(tree.prefix(4000))
    }

    /// ⚠️ THE GESTURE TEST. A real swipe, and the window holding after it.
    func testSwipingThroughClipsKeepsThemWithinTheBudget() throws {
        // Post indices are mock data and may not all be collections; the first
        // one carrying two clips is the subject. Reported rather than skipped
        // silently — a run that found none would otherwise read as a pass.
        var found: (app: XCUIApplication, probe: Probe)?
        // ⚠️ What each launch SAW is kept, not just whether it matched.
        //
        // A run that found nothing has two completely different causes — no
        // post carries two clips, or the probe never published at all — and the
        // first version of this test reported them with one message. That is the
        // same failure as an empty log reading like a clean one: the absence of
        // an answer was being read as an answer.
        var seenProbes: [String] = []
        for index in 0..<10 {
            let app = launch(startIndex: index)
            let observed = probe(in: app, timeout: index == 0 ? 20 : 6)
            seenProbes.append(observed.map { "page \(index): clips=\($0.clips)" }
                              ?? "page \(index): no probe")
            if let observed, observed.clips >= 2 {
                found = (app, observed)
                break
            }
            app.terminate()
        }
        let subject = try XCTUnwrap(
            found,
            "no collection with two clips was reached. What each launch saw:\n"
            + seenProbes.joined(separator: "\n")
        )
        let app = subject.app

        let media = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'carousel;'")).firstMatch
        var seen: [Probe] = [subject.probe]
        // ⚠️ Every PAGE, not every clip. The clips are pages two and three of
        // this gallery, so swiping once per clip stopped on a photograph and the
        // retention assertion read zero — a real failure of the test, not of the
        // feature, and indistinguishable from the real thing until the probe
        // started reporting how far the carousel goes.
        for _ in 0..<(subject.probe.pages - 1) {
            media.swipeLeft()
            guard let next = Probe(media.identifier) else {
                return XCTFail("the probe stopped answering after a swipe")
            }
            seen.append(next)
        }

        // The denominator first: a run where no swipe registered would satisfy
        // every bound below while proving nothing at all.
        XCTAssertGreaterThan(Set(seen.map(\.page)).count, 1,
                             "the swipes never moved the carousel")
        for probe in seen {
            XCTAssertLessThanOrEqual(probe.players, probe.capacity)
            XCTAssertLessThanOrEqual(probe.kept, probe.capacity)
        }
        // And the point of the whole thing: by the end, more than one clip is
        // being held — which is what a re-decode on every page change would not
        // produce.
        XCTAssertGreaterThan(seen.last?.kept ?? 0, 1)
    }
}
