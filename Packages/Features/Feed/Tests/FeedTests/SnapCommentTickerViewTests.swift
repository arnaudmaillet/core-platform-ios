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

            #expect(run(until: { !bubbleViews(ticker).isEmpty }))
            let first = bubbleViews(ticker)
            #expect(first.count == 1, "lane 0 alone enters first: \(first.count)")
            let flight = first.first?.layer.animation(forKey: "flight") as? CABasicAnimation
            let startX = (flight?.fromValue as? CGFloat) ?? 0
            let width = first.first?.bounds.width ?? 0
            #expect(abs(startX - (bandWidth + width / 2)) < 0.5, "it did not enter at the edge")
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
            #expect(run(until: { !bubbleViews(ticker).isEmpty }))
            let lanes = Set(bubbleViews(ticker).map { Int($0.frame.minY.rounded()) })
            #expect(lanes.count == 1, "more than one lane entered at once")
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
            #expect(run(until: { !bubbleViews(ticker).isEmpty }))
            #expect(bubbleViews(ticker).count == 1)
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
            #expect(run(until: { !bubbleViews(ticker).isEmpty }))
            #expect(bubbleViews(ticker).count == 1)
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

    /// Bug 3: the kinetic backdrop must engage during manual control — a
    /// visible wash while the coast is fast, disengaged at handover, where
    /// the dismissal fade owns the return to the resting level.
    @Test func kineticBackdropEngagesDuringCoastAndDisengagesAtHandover() throws {
        try hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setActive(true)
            ticker.debugFillBand()
            ticker.beginScrub()
            ticker.applyScrubTranslation(-40)
            ticker.endScrub(releaseVelocity: 1200)

            let blur = try #require(
                ticker.subviews.first { $0.accessibilityIdentifier == "ticker-kinetic-backdrop" }
            )
            // The ticker's own release stamp, not a fresh reading — see
            // `accumulatorSumsAbsoluteDeltasNotNetTranslation` for what a second
            // clock read costs on a loaded runner.
            let start = ticker.coastStartTime
            ticker.coastStep(now: start + 0.016) // one fast frame into the decay
            #expect(!blur.isHidden)
            #expect(ticker.currentKineticFraction > 0)
            #expect(abs(ticker.currentBackdropOpacity - ticker.currentKineticFraction) < 0.001)

            ticker.coastStep(now: start + 30) // decay long settled → handover
            #expect(ticker.currentKineticFraction == 0) // disengaged; reversal fades out
            let labels = bubbleViews(ticker)
            #expect(!labels.isEmpty)
            #expect(labels.allSatisfy { $0.layer.animation(forKey: "flight") != nil })
        }
    }

    /// At rest the wash sits at the viewer's Background setting — none by
    /// default — and a scrub raises it from there, never below it.
    @Test func theBackdropRestsAtTheViewersSettingAndScrubsRaiseIt() {
        hosting { window in
            let store = MediaCommentPreferencesStore(defaults: UserDefaults(suiteName: "ticker-rest-\(UUID().uuidString)")!)
            defer { SnapCommentTickerView.refreshAppearance(from: MediaCommentPreferencesStore(defaults: UserDefaults(suiteName: "reset-\(UUID().uuidString)")!)) }

            let bare = makeTicker(in: window)
            bare.appearanceStore = store
            bare.setActive(true)
            bare.debugFillBand()
            #expect(bare.currentBackdropOpacity == 0)

            store.update { $0.bandBackgroundOpacity = 0.3 }
            let ticker = makeTicker(in: window)
            ticker.appearanceStore = store
            ticker.setActive(true)
            ticker.debugFillBand()
            #expect(abs(ticker.currentBackdropOpacity - 0.3) < 0.001)

            ticker.beginScrub()
            ticker.applyScrubTranslation(-400)
            ticker.endScrub(releaseVelocity: 1200)
            ticker.coastStep(now: ticker.coastStartTime + 0.001)
            #expect(ticker.currentBackdropOpacity > 0.6)
            ticker.coastStep(now: ticker.coastStartTime + 30) // handover
            #expect(ticker.currentKineticFraction == 0)
        }
    }

    /// The backdrop is a true accumulator during a touch: monotone
    /// non-decreasing in accumulated absolute travel — floor at touch-down,
    /// cap at full travel, and NO velocity term anywhere in the mapping.
    @Test func scrubFractionIsAMonotoneNonDecayingAccumulator() {
        #expect(SnapCommentTickerView.scrubFraction(forAccumulatedDistance: 0) == SnapCommentTickerView.scrubEngagementFloor)
        #expect(SnapCommentTickerView.scrubFraction(forAccumulatedDistance: 10_000) == SnapCommentTickerView.maxBackdropOpacity)

        var previous: CGFloat = -1
        for distance in stride(from: CGFloat(0), through: 600, by: 20) {
            let fraction = SnapCommentTickerView.scrubFraction(forAccumulatedDistance: distance)
            #expect(fraction >= previous) // can build or hold, never drop
            previous = fraction
        }
    }

    /// The accumulator sums |Δx|, not net translation: scrubbing forward
    /// then all the way back builds intensity instead of cancelling out.
    @Test func accumulatorSumsAbsoluteDeltasNotNetTranslation() {
        hosting { window in
            let ticker = makeTicker(in: window)
            ticker.setActive(true)
            ticker.debugFillBand()
            ticker.beginScrub()
            ticker.applyScrubTranslation(-200)
            ticker.applyScrubTranslation(200) // net translation: zero
            ticker.endScrub(releaseVelocity: 1200)

            // Anchored to the release the ticker recorded, NOT to a fresh clock
            // reading: the gap between `endScrub` and this line is real elapsed
            // time, and on a loaded runner it is long enough for the fraction to
            // decay out of the assertion. This test is about the accumulator
            // summing |Δx|, not about how fast the machine got here.
            ticker.coastStep(now: ticker.coastStartTime + 0.001)
            // 400pt of absolute travel ≥ backdropDistanceScale → released at the cap.
            #expect(ticker.currentKineticFraction > SnapCommentTickerView.maxBackdropOpacity - 0.05)
        }
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
