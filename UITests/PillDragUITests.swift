import XCTest

/// Does a real finger get the gesture the rule says it should?
///
/// # Why this is a UITest
///
/// The component's own tests drive the drag through debug hooks, which enter
/// below the recognizer — they pin what the pill does once it has the touch,
/// and can say nothing about whether it gets it. Getting it is arbitration
/// between three recognizers over one finger (the grab, the strip's own pan,
/// and the `SelectorTouchProbe` every host attaches), and that is the half a
/// previous version of this gesture got wrong badly enough to be deleted.
///
/// The rule under test, in one sentence: **a drag that starts on the selection
/// pill drags the pill; every other drag on the capsule belongs to the strip.**
final class PillDragUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// For You: three tabs in the bottom accessory, indices into `AppTab`.
    /// ⚠️ `-select-tab` takes an INDEX; a name is a silent no-op that lands on
    /// Maps and fakes a missing selector.
    private static let forYou = "1"

    func testTheFingerOnThePillPagesAndTheFingerBesideItDoesNot() {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login", "-pill-drag-probe", "-select-tab", Self.forYou]
        app.launch()

        guard let resting = probe(in: app, timeout: 25, matches: { $0.hasBar && $0.tabs >= 2 }) else {
            return XCTFail("no selector to drag — last probe \(lastSeen(in: app) ?? "none")")
        }
        // Whichever tab the screen opens on, the drag goes to the neighbour it
        // has. Nothing here assumes a starting selection: For You opens on the
        // tab with unread arrivals, which is a product decision that may change
        // and would leave this test asserting the wrong direction.
        let target = resting.index == 0 ? 1 : resting.index - 1
        let pitch = resting.strip.width / CGFloat(resting.tabs)
        let travel = target > resting.index ? pitch : -pitch
        drag(in: app, from: resting.pill.midX, to: resting.pill.midX + travel, y: resting.pill.midY)

        guard let dragged = probe(in: app, timeout: 6, matches: { $0.index == target }) else {
            return XCTFail("the pill did not carry the pages from \(resting.index) to "
                + "\(target) — last probe \(lastSeen(in: app) ?? "none")")
        }

        XCTAssertEqual(dragged.grabs, 1, "the pages moved without the grab having taken the touch")

        // ⚠️ And now the other half, from the SAME bar in the same run: a drag
        // that starts on a segment the pill is NOT on must not reach the grab.
        // Aimed at the far side of the strip from the pill, and dragged right
        // across it — far enough that the release is nowhere near the segment it
        // started on, because `UIControl` keeps tracking a finger that strays
        // some tens of points outside its bounds and would otherwise land this
        // as an ordinary tap on the segment it began in.
        let elsewhere = dragged.pill.midX > dragged.strip.midX
            ? dragged.strip.minX + 20
            : dragged.strip.maxX - 20
        let across = elsewhere > dragged.pill.midX ? dragged.strip.minX + 4 : dragged.strip.maxX - 4
        drag(in: app, from: elsewhere, to: across, y: dragged.strip.midY)
        // Nothing to wait FOR, so this waits out the window in which the grab
        // would have shown up.
        _ = probe(in: app, timeout: 3, matches: { $0.grabs > dragged.grabs })
        let after = lastBand(in: app)
        XCTAssertEqual(after?.grabs, dragged.grabs,
                       "the grab took a touch that started beside the pill — that one "
                        + "belongs to the strip")
        XCTAssertEqual(after?.index, target,
                       "a drag that started beside the pill moved the selection")
    }

    /// Tapping is still how a tab is chosen. The grab begins on TOUCH-DOWN, so
    /// this is the check that it does not swallow the tap it begins under.
    func testTappingAnotherTabStillChangesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login", "-pill-drag-probe", "-select-tab", Self.forYou]
        app.launch()

        guard let resting = probe(in: app, timeout: 25, matches: { $0.hasBar && $0.tabs >= 2 }) else {
            return XCTFail("no selector to tap — last probe \(lastSeen(in: app) ?? "none")")
        }
        let target = resting.index == 0 ? 1 : resting.index - 1
        let pitch = resting.strip.width / CGFloat(resting.tabs)
        let aim = resting.pill.midX + (target > resting.index ? pitch : -pitch)
        tap(in: app, x: aim, y: resting.pill.midY)
        guard let tapped = probe(in: app, timeout: 6, matches: { $0.index == target }) else {
            return XCTFail("a tap on the neighbouring tab did not select it — last probe "
                + (lastSeen(in: app) ?? "none"))
        }
        // ⚠️ And the tap reached the SEGMENT rather than being absorbed. The
        // grab begins on touch-down, which is exactly the moment a tap starts:
        // this is the assertion that separates "the tap worked" from "the tap
        // worked for now".
        XCTAssertEqual(tapped.grabs, 0, "the grab took a tap that was not on the pill")
        XCTAssertEqual(tapped.taps, 1, "the segment never saw the tap")
    }

    // MARK: - Gestures

    /// Screen points → the normalized coordinates XCUITest wants. The probe
    /// reports the pill's rectangle in the window's own points, which is what
    /// the app draws in; the app element's frame is the same space.
    private func point(in app: XCUIApplication, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        let frame = app.frame
        return app.coordinate(withNormalizedOffset: CGVector(dx: x / frame.width,
                                                             dy: y / frame.height))
    }

    /// ⚠️ **PRESS, HOLD, THEN DRAG.** The grab is a zero-duration long press, so
    /// it takes the touch at touch-down — but a flick with no dwell is delivered
    /// as too few events to become a drag at all, and lands as a tap on whatever
    /// is under the finger. The hold is what makes this a drag rather than a
    /// very fast tap.
    private func drag(in app: XCUIApplication, from startX: CGFloat, to endX: CGFloat, y: CGFloat) {
        point(in: app, x: startX, y: y)
            .press(forDuration: 0.35, thenDragTo: point(in: app, x: endX, y: y),
                   withVelocity: .slow, thenHoldForDuration: 0.15)
    }

    private func tap(in app: XCUIApplication, x: CGFloat, y: CGFloat) {
        point(in: app, x: x, y: y).tap()
    }

    // MARK: - The probe channel

    private struct Band {
        let hasBar: Bool
        let index: Int
        let tabs: Int
        let pill: CGRect
        let strip: CGRect
        let offset: CGFloat
        let overflow: CGFloat
        /// How many touches the grab has taken since launch — the field that
        /// says WHICH gesture answered, where the selection only says what came
        /// out of it.
        let grabs: Int
        let taps: Int

        init?(_ identifier: String) {
            guard identifier.hasPrefix("pill;") else { return nil }
            var fields: [String: String] = [:]
            for pair in identifier.split(separator: ";").dropFirst() {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            func rect(_ key: String) -> CGRect {
                let numbers = (fields[key] ?? "").split(separator: ",").compactMap { Double($0) }
                guard numbers.count == 4 else { return .zero }
                return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            }
            hasBar = fields["bar"] == "1"
            index = Int(fields["index"] ?? "") ?? -1
            tabs = Int(fields["tabs"] ?? "") ?? 0
            pill = rect("pill")
            strip = rect("strip")
            offset = CGFloat(Double(fields["offset"] ?? "") ?? 0)
            overflow = CGFloat(Double(fields["overflow"] ?? "") ?? 0)
            grabs = Int(fields["grabs"] ?? "") ?? -1
            taps = Int(fields["taps"] ?? "") ?? -1
        }
    }

    private func lastSeen(in app: XCUIApplication) -> String? {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pill;'"))
            .firstMatch.identifier
    }

    private func lastBand(in app: XCUIApplication) -> Band? {
        lastSeen(in: app).flatMap(Band.init)
    }

    /// Polls, rather than reading once: the probe samples at 10Hz and a gesture
    /// lands on UIKit's clock, so the first identifier after one is routinely
    /// the pre-gesture sample.
    private func probe(in app: XCUIApplication, timeout: TimeInterval,
                       matches: (Band) -> Bool) -> Band? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let band = lastBand(in: app), matches(band) { return band }
            usleep(120_000)
        }
        return nil
    }
}
