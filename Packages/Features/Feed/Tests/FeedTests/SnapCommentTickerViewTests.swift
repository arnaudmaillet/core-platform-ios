import CoreStorage
import Testing
import UIKit
@testable import Feed

@MainActor
struct SnapCommentTickerViewTests {
    private let bandWidth: CGFloat = 400
    /// The band lays no train outside a window (a flight on a layer in no
    /// render tree completes at once and recycles its bubble), so every
    /// ticker under test is hosted, the way the page hosts it: in a visible
    /// window the test owns for exactly the length of `body`, and takes down
    /// before it returns.
    ///
    /// ⚠️ NOT a stored property of the suite. A `UIWindow` released while it
    /// is still visible, in the same run-loop turn that dirtied its layout,
    /// crashes the test host: its layer outlives it in the pending Core
    /// Animation transaction, and the next flush calls
    /// `layoutSublayersOfLayer:` on the freed window (NSZombie:
    /// `-[UIWindow methodForSelector:]: message sent to deallocated
    /// instance`; without zombies, EXC_BAD_ACCESS in
    /// `_sceneSafeAreaAlignedEdgesForFrame:inSuperview:`). A window stored on
    /// the suite dies with the suite instance, still visible, straight after
    /// a synchronous test mutated it. A race: 3 runs of this suite in 25
    /// crashed on the iOS 27 simulator (27 September 2026), and a crashed
    /// host takes down the rest of the package's run with it.
    private func hosting(_ body: (UIWindow) throws -> Void) rethrows {
        let window = makeHostWindow()
        defer { takeDown(window) }
        try body(window)
    }

    private func makeHostWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: bandWidth, height: 100))
        window.isHidden = false
        return window
    }

    /// Empties, hides and lays out the window, so nothing is left for a later
    /// flush to lay out once it is gone.
    private func takeDown(_ window: UIWindow) {
        window.subviews.forEach { $0.removeFromSuperview() }
        window.isHidden = true
        window.layoutIfNeeded()
    }

    /// A ticker with `itemCount` comments, in `window` (nil: in none).
    ///
    /// Its clock is PINNED (#993): a flight grabbed before its first committed
    /// frame — every flight in a synchronous test — is frozen at its start
    /// minus speed × elapsed, and on a starved runner the time between
    /// `setActive` and `beginScrub` carried the train out of the band a test
    /// reads. Pinned, the freeze lands exactly where the flight departed.
    private func makeTicker(itemCount: Int = 12, in window: UIWindow?) -> SnapCommentTickerView {
        let ticker = SnapCommentTickerView(frame: CGRect(x: 0, y: 0, width: bandWidth, height: 69))
        let now = CACurrentMediaTime()
        ticker.clock = { now }
        ticker.setComments((0..<itemCount).map { TickerCommentModel(id: "r\($0)", text: "GG 🔥 \($0)") })
        window?.addSubview(ticker)
        return ticker
    }

    /// Each bubble's model x and width, by its text and lane (its y): the
    /// same comment can fly in two lanes.
    private func positions(_ ticker: SnapCommentTickerView) -> [String: (x: CGFloat, width: CGFloat)] {
        var byKey: [String: (x: CGFloat, width: CGFloat)] = [:]
        for view in bubbleViews(ticker) {
            let text = view.subviews.compactMap { ($0 as? UILabel)?.text }.first ?? ""
            byKey["\(text)@\(Int(view.layer.position.y.rounded()))"] = (view.layer.position.x, view.bounds.width)
        }
        return byKey
    }

    /// The in-flight bubble CONTAINERS — each a `[avatar][text]` view whose
    /// own layer the conveyor animates on `position.x` (identified by
    /// carrying the text label). The flight animation and the scrub position
    /// live on the container, not the nested label.
    private func bubbleViews(_ ticker: SnapCommentTickerView) -> [UIView] {
        ticker.subviews.filter { view in view.subviews.contains { $0 is UILabel } }
    }

    /// Lets the band's spawn timers fire: `seconds` of the main run loop —
    /// for checking that nothing comes.
    private func run(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Runs the main run loop until `condition` holds, for at most `looks`
    /// turns of 10 ms; true when it held.
    /// ⚠️ A LOOK BUDGET, NOT A WALL-CLOCK DEADLINE: a starved runner can spend
    /// seconds before a spawn timer fires, and a deadline counts those
    /// seconds against the test (#1979, #1985).
    private func run(until condition: () -> Bool, looks: Int = 6_000) -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// ⚠️ THE BAND ARRIVES EMPTY (#2000, the owner 2026-11-01): activation
    /// places no bubble; lane 0's first one enters at the entry edge at once,
    /// as on Bilibili. It used to pre-fill every lane mid-stream.
    @Test func activationStartsEmptyAndEntersAtTheEdge() {
        hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setActive(true)
            #expect(bubbleViews(ticker).isEmpty, "the band was pre-filled")

            // Lane 0 is armed to enter at once, the others later: read from
            // the armed delays, not by counting bubbles after wall time — a
            // stalled runner fires two lanes' timers in one turn.
            let armed = ticker.debugArmedSpawnDelays
            #expect(armed.first == 0, "lane 0 does not enter at once")
            #expect(armed.dropFirst().allSatisfy { ($0 ?? 0) > 0 }, "another lane enters at once too")

            #expect(run(until: { !bubbleViews(ticker).isEmpty }))
            for bubble in bubbleViews(ticker) {
                let flight = bubble.layer.animation(forKey: "flight") as? CABasicAnimation
                let startX = (flight?.fromValue as? CGFloat) ?? 0
                #expect(abs(startX - (bandWidth + bubble.bounds.width / 2)) < 0.5, "it did not enter at the edge")
            }
        }
    }

    /// The lanes enter out of step: each one's first bubble after its own
    /// stagger (`laneEntryDelays`), never all at once.
    @Test func theLanesEnterStaggered() {
        let delays = SnapCommentTickerView.laneEntryDelays.prefix(SnapCommentTickerView.laneCount)
        #expect(delays.first == 0)
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 < $1 })
        hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setActive(true)
            // Each lane armed with its own stagger: deterministic, unlike
            // counting the lanes on screen after a wait.
            let armed = ticker.debugArmedSpawnDelays.compactMap { $0 }
            #expect(armed == Array(delays), "the lanes were not armed out of step: \(armed)")
        }
    }

    /// Paged back to, the app back in front: a page activated again starts
    /// empty, as every start does.
    @Test func aReactivationStartsEmpty() {
        hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setActive(true)
            ticker.debugFillBand()
            #expect(!bubbleViews(ticker).isEmpty)
            ticker.setActive(false)
            ticker.setActive(true)
            #expect(bubbleViews(ticker).isEmpty)
        }
    }

    /// A page can be configured and activated by the layout pass a
    /// presentation triggers, before its collection is in any window. A
    /// flight laid then completes at once (traced 25 September 2026). So the
    /// band starts nothing until it has a window, and starts the moment it
    /// gets one.
    @Test func activationBeforeTheWindowStartsOnArrival() {
        hosting { window in
            let ticker = makeTicker(in: nil)
            ticker.setActive(true)
            run(0.1)
            #expect(bubbleViews(ticker).isEmpty)

            window.addSubview(ticker)
            #expect(bubbleViews(ticker).isEmpty, "it arrived pre-filled")
            // Armed from the edge, lane 0 at once and the others later (not
            // a count of bubbles after wall time: a stalled runner fires two
            // lanes in one turn).
            #expect(ticker.debugArmedSpawnDelays.map { $0 ?? -1 } == Array(SnapCommentTickerView.laneEntryDelays.prefix(SnapCommentTickerView.laneCount)))
            #expect(run(until: { !bubbleViews(ticker).isEmpty }))
            #expect(bubbleViews(ticker).allSatisfy { $0.layer.animation(forKey: "flight") != nil })
        }
    }

    /// Held for a flight, an active band with content starts nothing: no
    /// bubble enters under the replica. The landing starts it, empty.
    @Test func aHeldBandStartsEmptyAtTheRelease() {
        hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setHeldForFlight(true)
            ticker.setActive(true)
            run(0.1)
            #expect(bubbleViews(ticker).isEmpty)

            ticker.setHeldForFlight(false)
            #expect(bubbleViews(ticker).isEmpty, "the landing pre-filled the band")
            // Armed from the edge, lane 0 at once and the others later (not
            // a count of bubbles after wall time: a stalled runner fires two
            // lanes in one turn).
            #expect(ticker.debugArmedSpawnDelays.map { $0 ?? -1 } == Array(SnapCommentTickerView.laneEntryDelays.prefix(SnapCommentTickerView.laneCount)))
            #expect(run(until: { !bubbleViews(ticker).isEmpty }))
        }
    }

    /// A reveal's landing (a flight that never held the chrome): what entered
    /// behind the replica goes, and the band starts empty.
    @Test func aRevealLandingStartsEmpty() {
        hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setActive(true)
            ticker.debugFillBand()
            ticker.replayEntrance()
            #expect(bubbleViews(ticker).isEmpty)
        }
    }

    /// ⚠️ A PAGE THAT LANDS JOINS THE POOL (#2005): comments that keep every
    /// old one merge into the tape; nothing on screen moves or restarts.
    @Test func aLandedPageMergesWithoutARestart() {
        hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setActive(true)
            ticker.debugFillBand()
            let before = positions(ticker)
            #expect(!before.isEmpty)

            ticker.setComments((0..<24).map { TickerCommentModel(id: "r\($0)", text: "GG 🔥 \($0)") })
            let after = positions(ticker)
            #expect(Set(after.keys) == Set(before.keys), "the band restarted on a merge")
        }
    }

    /// The band asks for more once two thirds of its pool were shown, and not
    /// again on the very next reads (#2005).
    @Test func twoThirdsShownAsksOnce() {
        hosting { window in
            let ticker = makeTicker(in: window)
            var asks = 0
            ticker.onRunningLow = { asks += 1 }
            ticker.setActive(true)
            ticker.debugFillBand()
            #expect(run(until: { asks > 0 }))
            #expect(asks == 1)
        }
    }

    @Test func deactivationClearsEveryBubble() {
        hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setActive(true)
            ticker.debugFillBand()
            #expect(!bubbleViews(ticker).isEmpty)

            ticker.setActive(false)
            #expect(bubbleViews(ticker).isEmpty)
        }
    }

    @Test func emptyQueueKeepsTheBandHiddenAndUnpopulated() {
        let ticker = SnapCommentTickerView(frame: CGRect(x: 0, y: 0, width: bandWidth, height: 69))
        ticker.setComments([])
        ticker.setActive(true)

        #expect(ticker.isHidden)
        #expect(bubbleViews(ticker).isEmpty)
    }

    // MARK: - Scrub

    /// Grabbing the band freezes CA flights into model positions: every
    /// bubble keeps an on-screen coordinate and no animation remains.
    @Test func beginScrubFreezesFlightsIntoModelPositions() {
        hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setActive(true)
            ticker.debugFillBand()

            ticker.beginScrub()

            let labels = bubbleViews(ticker)
            #expect(!labels.isEmpty)
            #expect(labels.allSatisfy { $0.layer.animation(forKey: "flight") == nil })
            // Frozen positions are the visible train, not the parked exit values.
            #expect(labels.contains { $0.layer.position.x > 0 })
        }
    }

    // MARK: - The past is what was shown (#2154)

    /// A band just started: lane 0's first bubble, grabbed where it entered.
    /// The spawn timers stop at the grab, so nothing else comes.
    private func grabbedAtStart(_ ticker: SnapCommentTickerView) -> UIView? {
        ticker.setActive(true)
        guard run(until: { !bubbleViews(ticker).isEmpty }) else { return nil }
        ticker.beginScrub()
        return bubbleViews(ticker).first
    }

    private func texts(_ ticker: SnapCommentTickerView) -> [String] {
        bubbleViews(ticker).compactMap { view in view.subviews.compactMap { ($0 as? UILabel)?.text }.first }
    }

    /// The owner's recording (2026-11-05): a drag in the first second filled
    /// both lanes edge to edge, the left backfill rewinding into reactions
    /// that never crossed the band.
    @Test func aScrubBackRightAfterActivationAddsNothingOnTheLeft() throws {
        try hosting { window in
            let ticker = makeTicker(in: window)
            let first = try #require(grabbedAtStart(ticker))
            let x = first.layer.position.x
            // ⚠️ WHAT STOOD AT THE GRAB, NOT THE FIRST BUBBLE ALONE: the lanes
            // enter staggered, and on a starved runner (#2180's CI, 298 s) the
            // next lane's entry fired before the grab — a second bubble at its
            // entry edge that the scrub did not make.
            let atGrab = Set(bubbleViews(ticker).map(ObjectIdentifier.init))
            ticker.applyScrubTranslation(20)
            let conjured = bubbleViews(ticker).filter { !atGrab.contains(ObjectIdentifier($0)) }
            #expect(conjured.isEmpty, "a backward scrub conjured \(texts(ticker))")
            #expect(bubbleViews(ticker).contains(first))
            #expect(abs(first.layer.position.x - (x + 20)) < 0.5)
        }
    }

    @Test func aScrubForwardAtTheStartBackfillsOnlyTheRight() throws {
        try hosting { window in
            let ticker = makeTicker(in: window)
            let first = try #require(grabbedAtStart(ticker))
            let left = first.frame.minX
            ticker.applyScrubTranslation(-150)
            let views = bubbleViews(ticker)
            #expect(views.count > 1, "nothing came in from the right")
            let leftmost = views.map(\.frame.minX).min() ?? 0
            #expect(abs(leftmost - (left - 150)) < 0.5, "a bubble appeared left of the first one")
        }
    }

    /// Scrubbed forward and back the same distance, the band is as it was:
    /// the first reaction where it stood, and nothing before it.
    @Test func aScrubBackRewindsExactlyWhatWasShown() throws {
        try hosting { window in
            let ticker = makeTicker(in: window)
            let first = try #require(grabbedAtStart(ticker))
            let text = texts(ticker).first
            let left = first.frame.minX
            for _ in 0..<6 { ticker.applyScrubTranslation(-50) }
            for _ in 0..<6 { ticker.applyScrubTranslation(50) }
            let views = bubbleViews(ticker)
            let leftmost = try #require(views.min { $0.frame.minX < $1.frame.minX })
            #expect(abs(leftmost.frame.minX - left) < 0.5)
            #expect(leftmost.subviews.compactMap { ($0 as? UILabel)?.text }.first == text)
        }
    }

    /// A drag that carries a lane's only bubble out on the right leaves the
    /// lane empty: it used to put the next one whole at the entry edge.
    @Test func anEmptiedLaneStaysEmptyOnABackwardDrag() throws {
        try hosting { window in
            let ticker = makeTicker(in: window)
            _ = try #require(grabbedAtStart(ticker))
            ticker.applyScrubTranslation(120)
            #expect(bubbleViews(ticker).isEmpty, "conjured \(texts(ticker))")
        }
    }

    /// A small pool, scrubbed back and forth: no reaction in both lanes.
    @Test func noReactionShowsInBothLanes() throws {
        try hosting { window in
            let ticker = makeTicker(itemCount: 3, in: window)
            _ = try #require(grabbedAtStart(ticker))
            let moves: [CGFloat] = Array(repeating: -80, count: 10) + Array(repeating: 80, count: 10) + [-200, 200, -300, 120]
            for dx in moves {
                ticker.applyScrubTranslation(dx)
                // Per lane (its y): a small pool repeats within a lane.
                var lanes: [Int: Set<String>] = [:]
                for view in bubbleViews(ticker) {
                    let text = view.subviews.compactMap { ($0 as? UILabel)?.text }.first ?? ""
                    lanes[Int(view.layer.position.y.rounded()), default: []].insert(text)
                }
                let sets = Array(lanes.values)
                let twins = sets.count < 2 ? [] : sets[0].intersection(sets[1])
                #expect(twins.isEmpty, "in both lanes after \(dx): \(twins)")
            }
        }
    }

    /// Dragging displaces the surviving bubbles exactly with the finger, and
    /// backfill keeps the band covered right up to the entry edge in both
    /// scrub directions.
    @Test func scrubTranslatesAndBackfillsBothDirections() {
        hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setActive(true)
            ticker.debugFillBand()
            ticker.beginScrub()

            // Only mid-band labels: ones near the left edge retire under the
            // translation and their (pooled) label can be reused by backfill in
            // the same pass, which would alias the identity check.
            let before = Dictionary(
                uniqueKeysWithValues: bubbleViews(ticker)
                    .filter { (150..<300).contains($0.layer.position.x) }
                    .map { ($0, $0.layer.position.x) }
            )
            #expect(!before.isEmpty)

            ticker.applyScrubTranslation(-120) // scrub forward
            for (label, x) in before {
                #expect(abs(label.layer.position.x - (x - 120)) < 0.5)
            }
            let rightmostAfterForward = bubbleViews(ticker).map { $0.frame.maxX }.max() ?? 0
            #expect(rightmostAfterForward > bandWidth - SnapCommentTickerView.interItemGap - 48)

            ticker.applyScrubTranslation(600) // scrub far backward: rewinds the queue
            let labels = bubbleViews(ticker)
            #expect(!labels.isEmpty)
            let leftmostAfterBackward = labels.map { $0.frame.minX }.min() ?? 0
            #expect(leftmostAfterBackward < SnapCommentTickerView.interItemGap + 48)
        }
    }

    /// ⚠️ THE GRAB IGNORES CORE ANIMATION'S MEDIA TIME (#1248). The scrub
    /// test above went red twice in loaded Feed runs (2026-10-15/16), when a
    /// grab froze each bubble where its `presentation()` was: on a starved
    /// runner, a commit and some media time slipped in between `setActive`
    /// and `beginScrub`, and the train moved out of the band the test reads.
    /// Since #1310 an in-flight bubble is frozen at the rightmost of the
    /// clock's position and the presentation's, never past where it departed.
    /// With the clock pinned, that is where it departed, whatever the render
    /// server did meanwhile. So a ticker committed, then left 0.2 s of media
    /// time before its grab, freezes exactly where an untouched one does.
    ///
    /// ⚠️ A FLIGHT CAN REALLY END MEANWHILE. Once committed, the flights run
    /// on real media time, and a bubble departing at the exit's edge has well
    /// under a second to fly: on a runner stalled for minutes (459 s for this
    /// test, 2026-10-19, #1429's Feed lane) it reached the exit, and its model
    /// rests there by design. Such a bubble may be found at the exit — only
    /// one whose whole flight fits in the time that really went by.
    @Test func aGrabFreezesTheSameTrainWhateverTheMediaTime() {
        hosting { window in
            let untouched = makeTicker(in: window)
            untouched.setActive(true)
            untouched.debugFillBand()
            untouched.beginScrub()
            let expected = positions(untouched)
            untouched.removeFromSuperview()

            let starved = makeTicker(in: window)
            starved.setActive(true)
            starved.debugFillBand()
            // What a starved runner did between the two calls: a commit (the
            // presentation exists) and media time running on.
            let committed = CACurrentMediaTime()
            CATransaction.flush()
            Thread.sleep(forTimeInterval: 0.2)
            let presented = bubbleViews(starved).compactMap { $0.layer.presentation() }
            starved.beginScrub()
            let elapsed = CGFloat(CACurrentMediaTime() - committed)
            let frozen = positions(starved)

            #expect(!expected.isEmpty)
            #expect(expected.count == bubbleViews(untouched).count, "two bubbles share a key")
            #expect(Set(frozen.keys) == Set(expected.keys), "not the same bubbles: \(frozen) vs \(expected)")
            let fastest = SnapCommentTickerView.laneSpeeds.max() ?? 0
            let wrong = frozen.filter { key, bubble in
                guard let want = expected[key]?.x else { return false }
                if abs(bubble.x - want) < 0.01 { return false }
                // At the exit, legitimately: its whole flight fitted in the
                // time that went by.
                let exit = -bubble.width / 2
                return !(abs(bubble.x - exit) < 0.01 && want - exit <= fastest * elapsed + 0.5)
            }
            #expect(wrong.isEmpty,
                    "the grab froze the train where the render server had moved it: \(frozen) vs \(expected), \(elapsed) s")
            // The witness: the presentation really had run on, so the
            // assertion above is not passing on a commit that never happened.
            #expect(!presented.isEmpty, "guard: the flush gave the bubbles a presentation")
        }
    }

    /// A release near the drift hands back to CA: flights reattach and the
    /// train keeps flowing. Needs a real window — flights on layers outside
    /// a render tree "complete" immediately, which would recycle everything.
    @Test func releaseHandsBubblesBackToTheConveyor() async throws {
        // Hosted by hand: `hosting` takes a synchronous body.
        let window = makeHostWindow()
        defer { takeDown(window) }
        let ticker = makeTicker(in: window)

        ticker.setActive(true)
        ticker.debugFillBand()
        ticker.beginScrub()
        ticker.applyScrubTranslation(-60)

        ticker.endScrub(releaseVelocity: -24) // near drift → immediate handover
        // Give the render server a beat; steady flights run for many seconds,
        // so the train must still be flowing afterwards.
        try await Task.sleep(for: .seconds(1.0))

        let labels = bubbleViews(ticker)
        #expect(!labels.isEmpty)
        // Time-dilation safe (a starved CI runner stretched this sleep to
        // 44s once, long enough for flights to finish): every label either
        // carries its flight, or has legitimately completed and rests at its
        // exit (negative x) awaiting the recycle completion.
        #expect(labels.allSatisfy {
            $0.layer.animation(forKey: "flight") != nil || $0.layer.position.x <= 0
        })
        // "At least one is still MID-flight" was the second half — and it is
        // pure wall-clock racing: a starved runner stretched the 1s sleep to
        // 66s once, every finite flight legitimately finished, and the line
        // reddened with no product defect behind it (the failure it hunted —
        // handover never happened, bubbles frozen mid-band — is a label with
        // NO animation at positive x, which the allSatisfy above already
        // catches). So the evidence accepted is "release produced motion":
        // in flight, or completed at its exit.
        #expect(labels.contains {
            $0.layer.animation(forKey: "flight") != nil || $0.layer.position.x <= 0
        })
    }

    // MARK: - Device-bug regressions (2026-07-13)

    /// Bug 1: the band's pan must preempt other pan recognizers (timeline
    /// slide-to-pop, pin grab) over its own frame — they are required to
    /// wait for the band's pan to fail.
    @Test func bandPanPreemptsOtherPanRecognizers() throws {
        try hosting { window in
            let ticker = makeTicker(in: window)
            let bandPan = try #require(ticker.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
            let dismissalPan = UIPanGestureRecognizer()
            let tap = UITapGestureRecognizer()

            #expect(ticker.gestureRecognizer(bandPan, shouldBeRequiredToFailBy: dismissalPan))
            // Taps (play/pause) are not held hostage.
            #expect(!ticker.gestureRecognizer(bandPan, shouldBeRequiredToFailBy: tap))
        }
    }

    /// Bug 2: the entry spawn is geometry-checked — an uncleared entry edge
    /// (e.g. the layer clock frozen by a percent-driven transition while
    /// wall-clock timers keep firing) defers the spawn instead of stacking a
    /// new bubble onto the frozen one.
    @Test func entrySpawnDefersUntilTheGapIsOpen() {
        // Rightmost bubble frozen exactly at the entry edge: the full
        // (width-independent) gap must elapse first.
        let blocked = SnapCommentTickerView.entryDeferral(lastRightEdge: 400, bandWidth: 400, speed: 22)
        #expect(abs(blocked - TimeInterval(SnapCommentTickerView.interItemGap / 22)) < 0.001)

        // Gap already open → no deferral.
        let clear = SnapCommentTickerView.entryDeferral(
            lastRightEdge: 400 - SnapCommentTickerView.interItemGap, bandWidth: 400, speed: 22
        )
        #expect(clear == 0)

        // Beyond-open never goes negative.
        #expect(SnapCommentTickerView.entryDeferral(lastRightEdge: 100, bandWidth: 400, speed: 22) == 0)
    }

    // MARK: - The letters' outline (#2339)

    /// No capsule surface, no mask, no blur and no layer shadow in the band
    /// (#2339 reverses #2172): at rest, during a scrub, in the coast and
    /// after the hand-back — and no wash rises on the drag.
    @Test func theBandDrawsNoCapsuleSurfaceOrMask() {
        hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setActive(true)
            ticker.debugFillBand()
            #expect(!ticker.debugBubbles.isEmpty)
            @MainActor func expectBare(_ moment: String, sourceLocation: SourceLocation = #_sourceLocation) {
                // Nothing in the band but its bubbles: no surface behind them.
                #expect(ticker.subviews.allSatisfy { $0 is TickerBubbleView }, "a surface in the band \(moment)",
                        sourceLocation: sourceLocation)
                #expect(ticker.layer.mask == nil, "the band masked \(moment)", sourceLocation: sourceLocation)
                #expect(ticker.layer.sublayers?.allSatisfy { sublayer in ticker.subviews.contains { $0.layer === sublayer } } ?? true,
                        "a capsule layer in the band \(moment)", sourceLocation: sourceLocation)
                for bubble in ticker.debugBubbles {
                    let label = bubble.debugLabel
                    #expect(bubble.mask == nil && bubble.layer.mask == nil && label.layer.mask == nil,
                            "a bubble masked \(moment)", sourceLocation: sourceLocation)
                    #expect(bubble.layer.shadowOpacity == 0 && label.layer.shadowOpacity == 0,
                            "a layer shadow on a moving bubble \(moment)", sourceLocation: sourceLocation)
                    #expect(!bubble.subviews.contains { $0 is UIVisualEffectView }, "a bubble carries a blur \(moment)",
                            sourceLocation: sourceLocation)
                    #expect(bubble.layer.sublayers?.allSatisfy { sublayer in bubble.subviews.contains { $0.layer === sublayer } } ?? true,
                            "a capsule layer rides a bubble \(moment)", sourceLocation: sourceLocation)
                    #expect(bubble.backgroundColor == nil,
                            "a bubble carries a fill \(moment)", sourceLocation: sourceLocation)
                }
            }
            expectBare("after a spawn")

            ticker.beginScrub()
            ticker.applyScrubTranslation(-60)
            ticker.applyScrubTranslation(25)
            expectBare("during a scrub")

            ticker.endScrub(releaseVelocity: 900)
            ticker.coastStep(now: ticker.coastStartTime + 0.016)
            expectBare("in the coast")

            ticker.coastStep(now: ticker.coastStartTime + 30) // handover
            #expect(ticker.debugIsConveying)
            expectBare("after the hand-back")
        }
    }

    /// The band's height, the corner's authority, does not move by a point.
    @Test func theBandHeightIsUnchanged() {
        let lane = max(20, ceil(UIFont.appFont(forTextStyle: .caption1).lineHeight) + 6)
        #expect(SnapCommentTickerView.bandHeight == 2 * lane + 3)
        let ticker = SnapCommentTickerView(frame: .zero)
        #expect(ticker.intrinsicContentSize.height == SnapCommentTickerView.bandHeight)
        #expect(TickerBubbleView.textInsets == UIEdgeInsets(top: 3, left: 0, bottom: 3, right: 0))
    }

    /// The outline: about 1 pt of black at 65 %; Increased Contrast widens it
    /// by a quarter point and makes it opaque.
    @Test func theOutlineFollowsTheContrastSetting() {
        let standard = TickerBubbleView.outline(increasedContrast: false)
        #expect(standard.width == 1)
        #expect(standard.color == UIColor(white: 0, alpha: 0.65))
        let contrast = TickerBubbleView.outline(increasedContrast: true)
        #expect(contrast.width == 1.25)
        #expect(contrast.color == UIColor(white: 0, alpha: 1))
    }

    /// The band reads Increased Contrast when its stream starts, and every
    /// bubble it lays wears that outline.
    @Test func everyBubbleWearsTheStreamsOutline() {
        hosting { window in
            let plain = makeTicker(in: window)
            plain.increasesContrast = { false }
            plain.setActive(true)
            plain.debugFillBand()
            #expect(!plain.debugBubbles.isEmpty)
            #expect(plain.debugBubbles.allSatisfy { $0.debugLabel.outline == TickerBubbleView.outline(increasedContrast: false) })

            let contrast = makeTicker(in: window)
            contrast.increasesContrast = { true }
            contrast.setActive(true)
            contrast.debugFillBand()
            #expect(!contrast.debugBubbles.isEmpty)
            #expect(contrast.debugBubbles.allSatisfy { $0.debugLabel.outline == TickerBubbleView.outline(increasedContrast: true) })
        }
    }

    /// The light shadow: black at 30 %, a 2 pt blur, no offset (drawn with
    /// `.zero` in `OutlinedTickerLabel.drawText(in:)`).
    @Test func theShadowIsLight() {
        #expect(TickerBubbleView.shadowColor == UIColor(white: 0, alpha: 0.3))
        #expect(TickerBubbleView.shadowBlur == 2)
        #expect(OutlinedTickerLabel.inkMargin >= TickerBubbleView.outline(increasedContrast: true).width + TickerBubbleView.shadowBlur,
                "the label's margin cuts the outline or its shadow")
    }

    /// The label's text box is the plain one: the bubble's text column, the
    /// label only `inkMargin` bigger all round for the ink past the letters.
    @Test func theLabelReachesPastTheTextBoxByItsMargin() {
        let bubble = TickerBubbleView()
        bubble.frame = CGRect(x: 0, y: 0, width: 160, height: 22)
        bubble.layoutIfNeeded()
        let textX = TickerBubbleView.avatarInset + TickerBubbleView.avatarDiameter + TickerBubbleView.avatarGap
        let margin = OutlinedTickerLabel.inkMargin
        let label = bubble.debugLabel
        #expect(label.frame == CGRect(x: textX - margin, y: -margin,
                                      width: 160 - textX - TickerBubbleView.trailingPadding + 2 * margin,
                                      height: 22 + 2 * margin))
        #expect(label.emoteTextRect(forBounds: label.bounds) == label.bounds.insetBy(dx: margin, dy: margin))
    }

    /// The pixels the label draws on a transparent ground: the count of
    /// white ones (the letters) and of dark, fairly opaque ones (the
    /// outline; the shadow alone stays under 30 %).
    private func inkCounts(_ outline: TickerBubbleView.TextOutline) -> (white: Int, dark: Int) {
        let label = OutlinedTickerLabel()
        label.font = TickerBubbleView.font
        label.textColor = .white
        label.text = "GG ae so good"
        label.outline = outline
        label.frame = CGRect(x: 0, y: 0, width: 160, height: 22 + 2 * OutlinedTickerLabel.inkMargin)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: label.bounds, format: format).image { _ in
            label.drawText(in: label.bounds)
        }
        guard let cgImage = image.cgImage else { return (0, 0) }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 0) }
        var white = 0, dark = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 0 else { continue }
            // Premultiplied: the colour over its alpha.
            let luminance = Int(pixels[index]) * 255 / alpha
            if alpha > 200, luminance > 200 { white += 1 }
            if alpha > 110, luminance < 90 { dark += 1 }
        }
        return (white, dark)
    }

    /// The outline is drawn OUTSIDE the letters: a dark ring the plain label
    /// doesn't have, and the white letters keep their full shape (a stroke
    /// across the glyph's edge would eat into them).
    @Test func theOutlineIsDrawnOutsideTheLetters() {
        let plain = inkCounts(TickerBubbleView.TextOutline(width: 0, color: .clear))
        let outlined = inkCounts(TickerBubbleView.outline(increasedContrast: false))
        #expect(plain.white > 100, "the label drew no letters: \(plain)")
        #expect(plain.dark == 0, "a ring without an outline: \(plain)")
        #expect(outlined.dark > plain.white / 4, "no ring around the letters: \(outlined) vs \(plain)")
        #expect(Double(outlined.white) >= Double(plain.white) * 0.85,
                "the outline ate into the letters: \(outlined.white) white pixels against \(plain.white)")
    }

    // MARK: - Decay math

    @Test func coastVelocityRelaxesToDriftWithoutOvershoot() {
        let release: CGFloat = 800
        let drift: CGFloat = -26
        var previous = release
        for step in 1...40 {
            let velocity = SnapCommentTickerView.coastVelocity(
                release: release, steadyDrift: drift, elapsed: TimeInterval(step) * 0.05
            )
            #expect(velocity < previous) // monotonic toward drift
            #expect(velocity > drift) // never overshoots past steady state
            previous = velocity
        }
        let settled = SnapCommentTickerView.coastVelocity(release: release, steadyDrift: drift, elapsed: 10)
        #expect(abs(settled - drift) < 0.01)
    }

    @Test func coastVelocityStartsAtTheReleaseVelocity() {
        let velocity = SnapCommentTickerView.coastVelocity(release: -300, steadyDrift: -22, elapsed: 0)
        #expect(abs(velocity - -300) < 0.01)
    }
}

/// A bubble's position from its two witnesses (#1310): the presentation can
/// lie to the LEFT right after a flight reattaches (it reports the exit the
/// model rests at), and is the truth to the RIGHT (a frozen layer clock).
struct TickerVisualCenterTests {
    /// Traced on the simulator: presentation 0, clock 442 — a live bubble
    /// read as gone, and the next one laid over it.
    @Test func aPresentationStuckAtTheExitNeverHidesALiveBubble() {
        #expect(SnapCommentTickerView.visualCenterX(analytic: 420, presented: -30, flightStart: 460) == 420)
    }

    /// A transition froze the layer clock: the bubble is where it was drawn.
    @Test func aFrozenClockKeepsTheDrawnPosition() {
        #expect(SnapCommentTickerView.visualCenterX(analytic: 200, presented: 260, flightStart: 300) == 260)
    }

    /// Never past where the flight departed.
    @Test func neverPastTheFlightsStart() {
        #expect(SnapCommentTickerView.visualCenterX(analytic: 200, presented: 900, flightStart: 300) == 300)
        #expect(SnapCommentTickerView.visualCenterX(analytic: 200, presented: nil, flightStart: 300) == 200)
    }
}
