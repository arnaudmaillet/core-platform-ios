import DesignSystem
import Testing
import UIKit
@testable import Feed

/// **The pull to the next / previous post (#2298 § 2), pure.** Past the
/// bottom end of a stream that scrolls → the next post, past its top → the
/// previous; the measure is the overscroll, the threshold the app's one pull
/// distance; only a finger's pull arms, and only a release past the
/// threshold goes.
@MainActor
struct PostPullTests {
    private let threshold = PostPullRule.threshold

    // MARK: - The measure

    @Test func theOverscrollIsMeasuredPastEachEnd() {
        // A 1 000 pt list in a 600 pt viewport, insets 100 / 50: its top
        // rests at -100, its tail at 1 000 + 50 - 600 = 450.
        func over(_ offset: CGFloat) -> [CGFloat] {
            let measured = PostPullRule.overscroll(
                offsetY: offset, topInset: 100, bottomInset: 50, contentHeight: 1_000, viewport: 600
            )
            return [measured.top, measured.bottom]
        }
        #expect(over(200) == [0, 0])
        #expect(over(-100) == [0, 0])
        #expect(over(450) == [0, 0])
        #expect(over(-160) == [60, 0])
        #expect(over(530) == [0, 80])
        // A list shorter than its viewport rests at its top: both ends there.
        let short = PostPullRule.overscroll(offsetY: -90, topInset: 100, bottomInset: 50, contentHeight: 200, viewport: 600)
        #expect(short.top == 0 && short.bottom == 10)
    }

    @Test func theProgressIsFullExactlyAtTheThreshold() {
        #expect(PostPullRule.progress(pulled: 0) == 0)
        #expect(PostPullRule.progress(pulled: threshold / 2) == 0.5)
        #expect(PostPullRule.progress(pulled: threshold) == 1)
        #expect(PostPullRule.progress(pulled: threshold * 2) == 1)
        #expect(threshold == PullRefreshRule.threshold, "the app's one pull distance")
    }

    // MARK: - The finger, the fling

    /// A finger's pull past the bottom end, beyond the threshold, then let go:
    /// the next post.
    @Test func aFingersPullPastTheThresholdGoesToTheNextPost() throws {
        var tracker = PostPullTracker()
        #expect(tracker.update(top: 0, bottom: 0, isTracking: true) { _ in true } == nil)
        let early = try #require(tracker.update(top: 0, bottom: 4, isTracking: true) { _ in true })
        #expect(early.direction == .next)
        #expect(!early.isShown, "the pill came out before the pull")
        let half = try #require(tracker.update(top: 0, bottom: threshold / 2, isTracking: true) { _ in true })
        #expect(half.isShown && !half.isArmed)
        let past = try #require(tracker.update(top: 0, bottom: threshold + 10, isTracking: true) { _ in true })
        #expect(past.isArmed)
        #expect(tracker.release() == .next)
    }

    /// The mirror: past the top → the previous post.
    @Test func aFingersPullPastTheTopGoesToThePreviousPost() {
        var tracker = PostPullTracker()
        _ = tracker.update(top: 20, bottom: 0, isTracking: true) { _ in true }
        let reading = tracker.update(top: threshold, bottom: 0, isTracking: true) { _ in true }
        #expect(reading?.direction == .previous)
        #expect(reading?.isArmed == true)
        #expect(tracker.release() == .previous)
    }

    /// Let go short of the threshold: nothing — the list springs back, the
    /// pill with it, disarmed.
    @Test func aReleaseShortOfTheThresholdDoesNothing() {
        var tracker = PostPullTracker()
        _ = tracker.update(top: 0, bottom: threshold - 20, isTracking: true) { _ in true }
        #expect(tracker.release() == nil)
        let back = tracker.update(top: 0, bottom: 30, isTracking: false) { _ in true }
        #expect(back?.isArmed == false, "the spring back follows the pill home")
        #expect(tracker.update(top: 0, bottom: 0, isTracking: false) { _ in true } == nil)
    }

    /// Back under the threshold before letting go disarms it.
    @Test func backUnderTheThresholdDisarms() {
        var tracker = PostPullTracker()
        _ = tracker.update(top: 0, bottom: 30, isTracking: true) { _ in true }
        _ = tracker.update(top: 0, bottom: threshold + 5, isTracking: true) { _ in true }
        #expect(tracker.isArmed)
        _ = tracker.update(top: 0, bottom: threshold - 5, isTracking: true) { _ in true }
        #expect(!tracker.isArmed)
        #expect(tracker.release() == nil)
    }

    /// ⚠️ A FLING NEVER GOES: the list reaching its end with no finger on it
    /// bounces with no pill, however far.
    @Test func aFlingReachingTheEndShowsNoPill() {
        var tracker = PostPullTracker()
        var asked = 0
        for bottom in [CGFloat(20), threshold, threshold + 40, 10] {
            #expect(tracker.update(top: 0, bottom: bottom, isTracking: false) { _ in asked += 1; return true } == nil)
        }
        #expect(tracker.release() == nil)
        #expect(asked == 0, "the feed was asked for a fling")
    }

    /// A finger catching a bounce already past the threshold did not pull it
    /// there: it arms only once it has been short of it under the finger.
    @Test func aCaughtBouncePastTheThresholdArmsOnlyOnceShort() {
        var tracker = PostPullTracker()
        let caught = tracker.update(top: 0, bottom: threshold + 30, isTracking: true) { _ in true }
        #expect(caught?.isArmed == false)
        #expect(tracker.release() == nil)
        var again = PostPullTracker()
        _ = again.update(top: 0, bottom: threshold + 30, isTracking: true) { _ in true }
        _ = again.update(top: 0, bottom: threshold - 10, isTracking: true) { _ in true }
        _ = again.update(top: 0, bottom: threshold + 10, isTracking: true) { _ in true }
        #expect(again.release() == .next)
    }

    /// ⚠️ NO PILL WITH NOWHERE TO GO: the feed's last post (no next), the
    /// first post's top (its close), the keyboard up — the host says no, once,
    /// as the pull begins.
    @Test func nowhereToGoShowsNoPillAndNeverGoes() {
        var tracker = PostPullTracker()
        var asked: [PostPullDirection] = []
        for bottom in [CGFloat(20), threshold + 20] {
            #expect(tracker.update(top: 0, bottom: bottom, isTracking: true) { asked.append($0); return false } == nil)
        }
        #expect(tracker.release() == nil)
        #expect(asked == [.next], "asked \(asked): a declined pull is asked once")
        var top = PostPullTracker()
        #expect(top.update(top: threshold + 20, bottom: 0, isTracking: true) { $0 == .next } == nil)
        #expect(top.release() == nil, "the first post's top went back")
    }

    /// The host is asked once per pull, as it begins — not on every frame.
    @Test func theHostIsAskedOncePerPull() {
        var tracker = PostPullTracker()
        var asked = 0
        for bottom in [CGFloat(10), 40, 80, 130] {
            _ = tracker.update(top: 0, bottom: bottom, isTracking: true) { _ in asked += 1; return true }
        }
        #expect(asked == 1)
        _ = tracker.update(top: 0, bottom: 0, isTracking: true) { _ in true }
        _ = tracker.update(top: 0, bottom: 12, isTracking: true) { _ in asked += 1; return true }
        #expect(asked == 2, "a new pull asks again")
    }

    // MARK: - A stream that fits

    /// A stream its room holds whole pages with the feed: up to the next
    /// post; down to the previous one only when the feed has one to give —
    /// the first post keeps its close. Sideways is the tabs'.
    @Test func aStreamThatFitsPagesWithTheFeed() {
        let up = CGPoint(x: 0, y: -900)
        let down = CGPoint(x: 0, y: 900)
        #expect(PostPullRule.fittingStreamSwipe(velocity: up, translation: .zero, pagesBack: false) == .next)
        #expect(PostPullRule.fittingStreamSwipe(velocity: down, translation: .zero, pagesBack: true) == .previous)
        #expect(PostPullRule.fittingStreamSwipe(velocity: down, translation: .zero, pagesBack: false) == nil,
                "the first post keeps its close")
        #expect(PostPullRule.fittingStreamSwipe(velocity: CGPoint(x: -900, y: -300), translation: .zero, pagesBack: true) == nil,
                "a sideways drag is the tabs'")
        #expect(PostPullRule.fittingStreamSwipe(velocity: .zero, translation: CGPoint(x: 0, y: -12), pagesBack: false) == .next)
        #expect(PostPullRule.fittingStreamSwipe(velocity: .zero, translation: .zero, pagesBack: true) == nil)
    }

    /// The feed is asked only for a drag that goes back.
    @Test func theFeedIsAskedOnlyForADragThatGoesBack() {
        var asked = 0
        func pagesBack() -> Bool { asked += 1; return true }
        _ = PostPullRule.fittingStreamSwipe(velocity: CGPoint(x: 0, y: -900), translation: .zero, pagesBack: pagesBack())
        _ = PostPullRule.fittingStreamSwipe(velocity: CGPoint(x: 900, y: 100), translation: .zero, pagesBack: pagesBack())
        #expect(asked == 0)
    }

    // MARK: - The pill

    private func pill(reducesMotion: Bool = true) -> PostPullPill {
        let pill = PostPullPill(reducesMotion: { reducesMotion })
        pill.configure(direction: .next, target: PostPullTarget(authorName: "Ava Moreau", monogram: "AM"), pipeline: nil)
        pill.frame = CGRect(x: 0, y: 0, width: 300, height: PostPullPill.height)
        pill.layoutIfNeeded()
        return pill
    }

    private func reading(_ pulled: CGFloat, armed: Bool = false, direction: PostPullDirection = .next) -> PostPullTracker.Reading {
        PostPullTracker.Reading(
            direction: direction, pulled: pulled, progress: PostPullRule.progress(pulled: pulled),
            isArmed: armed, isShown: pulled >= PostPullRule.appearLift
        )
    }

    /// Its words: "Next post", then "Release for the next post" at the
    /// threshold; the mirror for the previous post.
    @Test func theWordsChangeAtTheThreshold() {
        #expect(PostPullPill.words(.next, armed: false) == "Next post")
        #expect(PostPullPill.words(.next, armed: true) == "Release for the next post")
        #expect(PostPullPill.words(.previous, armed: false) == "Previous post")
        #expect(PostPullPill.words(.previous, armed: true) == "Release for the previous post")
        let pill = pill(reducesMotion: false)
        pill.apply(reading(threshold / 2))
        #expect(pill.isShown)
        #expect(pill.debugLine == "Next post")
        #expect(abs(pill.debugRingFill - 0.5) < 0.01, "the ring does not fill with the pull")
        let narrow = pill.width(limit: 400)
        pill.apply(reading(threshold, armed: true))
        #expect(pill.debugLine == "Release for the next post")
        #expect(pill.debugRingFill == 1)
        #expect(pill.width(limit: 400) > narrow, "the capsule does not hold its longer words")
        #expect(pill.width(limit: 120) <= 120)
        pill.retract()
        #expect(!pill.isShown)
        #expect(pill.debugLine == "Next post")
    }

    /// Reduce Motion: the ring does not fill with the pull — empty, then full
    /// at the threshold.
    @Test func underReduceMotionTheRingDoesNotFillWithThePull() {
        let pill = pill(reducesMotion: true)
        pill.apply(reading(threshold / 2))
        #expect(pill.isShown)
        #expect(pill.debugRingFill == 0)
        pill.apply(reading(threshold, armed: true))
        #expect(pill.debugRingFill == 1)
    }

    /// The threshold's haptic: the app's role (`armed`), once per crossing,
    /// none while it holds past it or falls back.
    @Test func itTicksOncePerCrossing() {
        let pill = pill()
        let played = HapticRecorder.recording {
            pill.apply(reading(threshold / 2))
            pill.apply(reading(threshold + 5, armed: true))
            pill.apply(reading(threshold + 20, armed: true))
            pill.apply(reading(threshold - 10))
            pill.apply(reading(threshold - 20))
        }
        #expect(played == [.armed], "played \(played)")
    }
}
