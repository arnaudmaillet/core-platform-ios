import Testing
import UIKit
@testable import Feed

/// THE BAR PILLS' CONTENT BLURS ACROSS, INSIDE ONE ITEM.
///
/// `BarItemContentTransition` is what replaced iOS 26's native item morph for
/// the feed's author pill and audio capsule: the old content fades into a
/// blurred still of itself, the change is applied at the midpoint, and the new
/// content comes back sharp out of a blurred still of ITSELF. These pin the
/// timeline's contract — when the change lands, what is on the host meanwhile,
/// and that nothing is left behind.
@MainActor
struct BarItemContentTransitionTests {
    /// A host with one label in an edge-pinned content container — the pills'
    /// own structure.
    @MainActor
    private final class Host {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 36))
        let content = UIView()
        let label = UILabel()
        let transition: BarItemContentTransition

        init() {
            content.frame = view.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(content)
            label.text = "Old"
            label.frame = content.bounds
            content.addSubview(label)
            transition = BarItemContentTransition(host: view, content: content)
        }

        /// The stills: whatever the transition added to the host beside the
        /// content.
        var stills: [UIView] { view.subviews.filter { $0 !== content } }
    }

    private static func window(showing host: Host) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.addSubview(host.view)
        window.isHidden = false
        return window
    }

    private static func settle(_ host: Host) async throws {
        for _ in 0..<200 where host.transition.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Off screen there is nothing to see: the change lands in this turn.
    @Test func anOffscreenChangeLandsAtOnce() {
        let host = Host()

        host.transition.perform(animated: true) { host.label.text = "New" }

        #expect(host.label.text == "New")
        #expect(host.stills.isEmpty)
        #expect(host.content.alpha == 1)
        #expect(host.transition.isRunning == false)
    }

    /// On screen the OLD content is what fades: the change waits for the
    /// midpoint, and the content is left sharp and alone at the end.
    @Test func anOnScreenChangeLandsAtTheMidpointAndLeavesNothingBehind() async throws {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }

        host.transition.perform(animated: true) { host.label.text = "New" }

        #expect(host.label.text == "Old", "the change landed before the old content had faded")
        #expect(host.transition.isRunning)
        #expect(host.content.alpha == 0, "the live content is not the thing fading out")
        if !UIAccessibility.isReduceMotionEnabled {
            #expect(host.stills.count == 1, "no blurred still of the old content")
        }

        try await Self.settle(host)

        #expect(host.label.text == "New")
        #expect(host.stills.isEmpty, "a still outlived its transition")
        #expect(host.content.alpha == 1)
    }

    /// Everything asked for while the old content fades lands in ONE swap —
    /// how a new author and their follow badge arrive together.
    @Test func changesAskedForDuringTheFadeLandInOneSwap() async throws {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }
        // What the label said when the second change ran: "New" means the
        // two landed in one swap, back to back.
        var textAtSecondChange: String?

        host.transition.perform(animated: true) { host.label.text = "New" }
        host.transition.perform(animated: true) {
            textAtSecondChange = host.label.text
            host.label.textAlignment = .right
        }
        #expect(textAtSecondChange == nil, "the second change landed before the fade")
        try await Self.settle(host)

        #expect(host.label.text == "New")
        #expect(host.label.textAlignment == .right)
        #expect(textAtSecondChange == "New")
    }

    /// A late arrival for the new content (a fetched face) waits for the swap
    /// rather than landing on the old content mid-fade.
    @Test func aLateArrivalWaitsForTheSwap() async throws {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }

        host.transition.perform(animated: true) { host.label.text = "New" }
        var order: [String] = []
        host.transition.afterSwap { order.append(host.label.text ?? "") }
        #expect(order.isEmpty)
        try await Self.settle(host)

        #expect(order == ["New"])
    }

    /// Interrupted, a transition jumps to its end: the pending change applied,
    /// no still left, the content opaque.
    @Test func finishJumpsToTheEnd() {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }

        host.transition.perform(animated: true) { host.label.text = "New" }
        host.transition.finish()

        #expect(host.label.text == "New")
        #expect(host.stills.isEmpty)
        #expect(host.content.alpha == 1)
        #expect(host.transition.isRunning == false)
    }

    // MARK: - Scroll-driven

    /// The scroll sets the blur: the live content fades against ONE still of
    /// itself, by exactly the amount asked, frame after frame — and a frame
    /// adds nothing to the host.
    @Test func theScrollSetsTheBlur() {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }

        host.transition.setScrubBlur(0.4)
        #expect(abs(host.content.alpha - 0.6) < 1e-6)
        #expect(host.transition.isRunning)
        if !UIAccessibility.isReduceMotionEnabled {
            #expect(host.stills.count == 1)
            #expect(abs((host.stills.first?.alpha ?? 0) - 0.4) < 1e-6)
        }
        let still = host.stills.first

        host.transition.setScrubBlur(0.9)
        #expect(abs(host.content.alpha - 0.1) < 1e-6)
        #expect(host.stills.first === still, "a frame re-rendered the still")
        #expect(host.stills.count == (still == nil ? 0 : 1))
    }

    /// A change asked for under the scroll's blur lands at the next frame,
    /// UNDER the blur — never on the clock's timeline — and the blur keeps
    /// following the scroll.
    @Test func aChangeUnderTheScrollLandsUnderTheBlur() {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }
        var applied = 0

        host.transition.setScrubBlur(1)
        host.transition.perform(animated: true) {
            applied += 1
            host.label.text = "New"
        }
        host.transition.setScrubBlur(1)

        #expect(host.label.text == "New")
        #expect(applied == 1)
        #expect(host.content.alpha == 0, "the swap showed the live content")
        #expect(host.transition.scrubBlur == 1)
    }

    /// Back at 0 the stills go and the live content is alone — and the host
    /// hears of a landing only when the scrub swapped something.
    @Test func backAtZeroTheContentIsAloneAgain() {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }
        var settled = 0
        host.transition.didSettle = { settled += 1 }

        host.transition.setScrubBlur(0.5)
        host.transition.setScrubBlur(0)
        #expect(settled == 0, "a scrub that swapped nothing reported a landing")
        #expect(host.stills.isEmpty)
        #expect(host.content.alpha == 1)
        #expect(host.transition.isRunning == false)

        // A scrub that swapped: its envelope runs out on the clock first.
        let clock = Clock()
        host.transition.now = { clock.time }
        host.transition.ticksOnDisplay = false
        host.transition.setScrubBlur(1)
        host.transition.perform(animated: true) { host.label.text = "New" }
        host.transition.setScrubBlur(1)
        host.transition.setScrubBlur(0.3)
        host.transition.setScrubBlur(0)
        #expect(settled == 0, "landed while the swap's envelope still blurs it")
        clock.time += BarItemContentTransition.swapHold + BarItemContentTransition.swapRelease
        host.transition.tick()
        #expect(settled == 1)
        #expect(host.stills.isEmpty)
        #expect(host.content.alpha == 1)
    }

    // MARK: - A swap is always seen blurred (#627)

    /// A clock the test winds by hand.
    @MainActor
    final class Clock {
        var time: CFTimeInterval = 1_000
    }

    private func onTheClock(_ host: Host) -> Clock {
        let clock = Clock()
        host.transition.now = { clock.time }
        host.transition.ticksOnDisplay = false
        return clock
    }

    @Test func theEnvelopeHoldsThenReleases() {
        let hold = BarItemContentTransition.swapHold
        let release = BarItemContentTransition.swapRelease
        #expect(BarItemContentTransition.swapEnvelope(after: 0) == 1)
        #expect(BarItemContentTransition.swapEnvelope(after: hold * 0.9) == 1)
        #expect(abs(BarItemContentTransition.swapEnvelope(after: hold + release / 2) - 0.5) < 1e-6)
        #expect(BarItemContentTransition.swapEnvelope(after: hold + release) == 0)
        #expect(hold + release >= 0.15, "the agreed minimum is ~150 ms of blur after a swap")
    }

    /// The swap frame is FULL blur whatever the scroll's blur was, and the
    /// blur outlives a scroll that has already stopped: it is released on
    /// the clock, with the stills kept until it is gone.
    @Test func aSwapIsMadeUnderFullBlurAndOutlivesTheScroll() {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }
        let clock = onTheClock(host)
        var settled = 0
        host.transition.didSettle = { settled += 1 }

        // A fast frame: the scroll's blur is only 0.3 when the swap comes.
        host.transition.setScrubBlur(0.3)
        host.transition.perform(animated: true) { host.label.text = "New" }
        host.transition.setScrubBlur(0.3)
        #expect(host.label.text == "New")
        #expect(host.transition.scrubBlur == 1, "the swap was made with sharp content showing")
        #expect(host.content.alpha == 0)

        // The page lands on the next frame: the scroll says 0.
        host.transition.setScrubBlur(0)
        #expect(host.transition.scrubBlur == 1, "the blur ended with the scroll")
        #expect(host.transition.isRunning)
        if !UIAccessibility.isReduceMotionEnabled { #expect(!host.stills.isEmpty) }

        clock.time += BarItemContentTransition.swapHold + BarItemContentTransition.swapRelease / 2
        host.transition.tick()
        #expect(abs(host.transition.scrubBlur - 0.5) < 1e-6)
        #expect(abs(host.content.alpha - 0.5) < 1e-6)
        #expect(settled == 0)

        clock.time += BarItemContentTransition.swapRelease
        host.transition.tick()
        #expect(host.transition.scrubBlur == 0)
        #expect(host.content.alpha == 1)
        #expect(host.stills.isEmpty)
        #expect(settled == 1)
        #expect(!host.transition.isRunning)
    }

    /// A fling, sampled as a display would: few frames per page. Every swap
    /// is made under full blur, and the pill stays blurred at least the
    /// agreed minimum after it, at 60 and 120 Hz up to 9,000 pt/s.
    @Test(arguments: [(60.0, 6_000.0), (60.0, 9_000.0), (120.0, 6_000.0), (120.0, 9_000.0)])
    func aFlingIsSeenBlurred(hz: Double, speed: Double) {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }
        let clock = onTheClock(host)
        let page = 874.0
        var scrub = BarPillScrub()
        scrub.settle(at: 0)
        var swapBlur: CGFloat?
        var swapTime: CFTimeInterval?
        var lastBlurred: CFTimeInterval?

        // From rest on page 0 to rest on page 1, then a few frames at rest.
        var offset = 0.0
        while true {
            offset = min(offset + speed / hz, page)
            let position = CGFloat(offset / page)
            let blur = BarPillScrub.frame(position: position, itemCount: 2)?.blur ?? 0
            host.transition.setScrubBlur(blur)
            if scrub.update(position: position, itemCount: 2) != nil {
                host.transition.perform(animated: true) { host.label.text = "New" }
                host.transition.setScrubBlur(blur)
                swapBlur = host.transition.scrubBlur
                swapTime = clock.time
            }
            host.transition.tick()
            if host.transition.scrubBlur > 0 { lastBlurred = clock.time }
            clock.time += 1 / hz
            if offset >= page, !host.transition.isRunning { break }
            if clock.time > 1_010 { break }
        }

        #expect(host.label.text == "New")
        // The window jumped in one frame at the fastest speeds: the swap then
        // runs on the clock's timeline instead (`aFrameThatJumpsTheWindow…`).
        if let swapBlur, let swapTime, let lastBlurred {
            #expect(swapBlur == 1, "swapped at blur \(swapBlur)")
            #expect(lastBlurred - swapTime >= 0.15, "blurred \((lastBlurred - swapTime) * 1000) ms after the swap")
        }
    }

    /// One frame jumps the whole blur window (a fling's dropped frame): the
    /// scroll's blur is 0 on the swap frame, so the change takes the clock's
    /// timeline — and the frame's second call at 0 no longer flushes it to a
    /// hard cut.
    @Test func aFrameThatJumpsTheWindowStillBlursOnTheClock() {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }

        host.transition.setScrubBlur(0)
        host.transition.perform(animated: true) { host.label.text = "New" }
        host.transition.setScrubBlur(0)

        #expect(host.label.text == "Old", "the change was cut in sharp")
        #expect(host.transition.isRunning, "no blur ran for the change")
    }

    /// A slow drag still follows the finger: a held finger keeps the full
    /// blur, and once the envelope is spent the blur is exactly the scroll's.
    @Test func aSlowDragFollowsTheFinger() {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }
        let clock = onTheClock(host)

        host.transition.setScrubBlur(1)
        host.transition.perform(animated: true) { host.label.text = "New" }
        host.transition.setScrubBlur(1)
        clock.time += 1
        host.transition.setScrubBlur(1)
        #expect(host.transition.scrubBlur == 1, "a held finger lost its blur")

        let drawn = BarPillScrub.blur(coverage: 0.6)
        host.transition.setScrubBlur(drawn)
        #expect(abs(host.transition.scrubBlur - drawn) < 1e-6)
        #expect(abs(host.content.alpha - (1 - drawn)) < 1e-6)
    }

    /// A still prepared at a drag's start is the one the scrub shows, and a
    /// drag that never blurred leaves nothing behind.
    @Test func aPreparedStillIsUsedOrDropped() {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        host.transition.prepareScrub()
        #expect(host.stills.count == 1)
        #expect(host.stills.first?.alpha == 0)
        let prepared = host.stills.first
        host.transition.setScrubBlur(0.2)
        #expect(host.stills.first === prepared)
        host.transition.setScrubBlur(0)
        #expect(host.stills.isEmpty)

        host.transition.prepareScrub()
        host.transition.setScrubBlur(0)
        #expect(host.stills.isEmpty, "a prepared still outlived the drag")
    }

    /// A scroll that starts blurring while the clock's swap is fading out
    /// takes over from its end: the change applied, one owner.
    @Test func theScrollTakesOverATimedSwap() {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }

        host.transition.perform(animated: true) { host.label.text = "New" }
        host.transition.setScrubBlur(0.5)

        #expect(host.label.text == "New")
        #expect(abs(host.content.alpha - 0.5) < 1e-6)
        #expect(host.stills.count <= 1)
    }

    /// The still is the view's bounds grown by the blur's reach, so the blur
    /// fades out instead of being cut at the view's edge.
    @Test func theStillCoversTheBlursReach() throws {
        let host = Host()
        let (image, frame) = try #require(
            BarItemContentTransition.blurredSnapshot(of: host.content, radius: 4)
        )

        #expect(frame.contains(host.content.bounds))
        #expect(frame.width > host.content.bounds.width)
        #expect(abs(image.size.width - frame.width) < 0.5)
        #expect(abs(image.size.height - frame.height) < 0.5)
    }
}
