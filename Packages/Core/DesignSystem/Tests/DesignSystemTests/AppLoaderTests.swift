import CoreGraphics
import Testing
import UIKit
@testable import DesignSystem

/// The branded loader (#1329, #1795): three pills rippling as a continuous
/// wave — its geometry, the one function of time the pull and the loop both
/// read, the hand-off between them, and the view's lifecycle rules.
@MainActor
struct AppLoaderTests {
    private typealias Geometry = AppLoaderGeometry
    private typealias Timeline = AppLoaderTimeline

    // MARK: - Geometry

    /// Three pills and two gaps of 0.3 × a pill span the square; a dot is a
    /// circle, the peak 2.5 × the width, all centred.
    @Test(arguments: [CGFloat(20), 37])
    func threePillsSpanTheSquare(_ side: CGFloat) {
        let width = Geometry.pillWidth(side: side)
        #expect(abs(3 * width + 2 * 0.3 * width - side) < 0.001)
        let dot = Geometry.pillFrame(0, height: 0, side: side)
        #expect(abs(dot.height - width) < 0.001, "a dot is not a circle")
        let peak = Geometry.pillFrame(2, height: 1, side: side)
        #expect(abs(peak.height - 2.5 * width) < 0.001)
        #expect(abs(peak.maxX - side) < 0.001, "the last pill does not end at the square's edge")
        #expect(abs(peak.midY - side / 2) < 0.001, "the pill is not centred")
        #expect(peak.height <= side, "the peak leaves the square")
    }

    // MARK: - The wave

    /// One continuous cosine with a 1.2 s period: a dot at 0, the peak at
    /// half the period, a dot again, never a hold.
    @Test func theWaveIsAContinuousCosine() {
        #expect(Timeline.period == 1.2)
        #expect(Timeline.wave(at: 0) == 0)
        #expect(abs(Timeline.wave(at: 0.6) - 1) < 0.000_001)
        #expect(abs(Timeline.wave(at: 1.2)) < 0.000_001)
        #expect(abs(Timeline.wave(at: 0.3) - 0.5) < 0.000_001)
        // No plateau: the height changes between any two nearby times
        // except at the very turn of the cosine.
        for step in 1..<119 where step != 60 {
            let t = Double(step) / 100
            #expect(Timeline.wave(at: t) != Timeline.wave(at: t + 0.01), "the wave holds at \(t)")
        }
    }

    /// Each pill runs a sixth of a cycle behind the one before it.
    @Test func eachPillRunsASixthBehind() {
        #expect(abs(Timeline.stagger - Timeline.period / 6) < 0.000_001)
        for t in stride(from: 0.4, through: 3, by: 0.1) {
            #expect(abs(Timeline.height(pill: 1, at: t) - Timeline.height(pill: 0, at: t - 0.2)) < 0.000_001)
            #expect(abs(Timeline.height(pill: 2, at: t) - Timeline.height(pill: 1, at: t - 0.2)) < 0.000_001)
        }
    }

    /// The lead is its pill, 0.1 s ahead, once the wave is under way.
    @Test func theLeadRunsAheadOfItsPill() {
        for t in stride(from: 0.5, through: 3, by: 0.1) {
            for pill in 0..<3 {
                #expect(abs(Timeline.leadHeight(pill: pill, at: t) - Timeline.height(pill: pill, at: t + 0.1)) < 0.000_001)
            }
        }
    }

    // MARK: - The pull

    /// Pull 0 is three dots, and their leads too.
    @Test func pullZeroIsThreeDots() {
        let frame = Timeline.pull(0)
        #expect(frame.heights == [0, 0, 0])
        #expect(frame.leadHeights == [0, 0, 0])
    }

    /// Scrubbable both ways: the same progress always gives the same frame,
    /// and neighbouring progresses give neighbouring frames.
    @Test func thePullIsContinuousAndReversible() {
        var previous = Timeline.pull(0)
        for step in 1...200 {
            let progress = CGFloat(step) / 200
            let frame = Timeline.pull(progress)
            #expect(frame == Timeline.pull(progress))
            for (a, b) in zip(frame.heights + frame.leadHeights, previous.heights + previous.leadHeights) {
                #expect(abs(a - b) < 0.05, "the pull jumped at \(progress)")
            }
            previous = frame
        }
        #expect(Timeline.pullTime(1) == Timeline.period, "a full pull is not one cycle")
    }

    /// A pill stays a dot until its own time starts.
    @Test func eachPillWaitsForItsOwnStart() {
        #expect(Timeline.height(pill: 1, at: 0.19) == 0)
        #expect(Timeline.height(pill: 2, at: 0.39) == 0)
        #expect(Timeline.height(pill: 2, at: 0.41) > 0)
    }

    // MARK: - The loop

    /// The loop repeats one cycle with no seam, and stands where the pull
    /// left it: the cycle time of each pill at `t` gives the pull's height.
    @Test(arguments: [CGFloat(0), 0.15, 0.4, 0.7, 1])
    func theLoopTakesOverWhereThePullLeftIt(_ progress: CGFloat) {
        let samples = Timeline.cycleSamples()
        #expect(samples.first == samples.last, "the cycle has a seam")
        let t = Timeline.pullTime(progress)
        for pill in 0..<3 {
            let own = Timeline.cycleTime(pill: pill, at: t)
            let loop = own < 0 ? 0 : Timeline.wave(at: own)
            #expect(abs(loop - Timeline.height(pill: pill, at: t)) < 0.000_001, "pill \(pill) jumps at \(progress)")
        }
    }

    // MARK: - The view

    private func loader(reducesMotion: Bool = false) -> (AppLoaderView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let view = AppLoaderView(size: .large)
        view.reducesMotion = { reducesMotion }
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return (view, window)
    }

    /// Hidden when stopped, shown while pulled or loading, like the stock spinner.
    @Test func itHidesWhenStopped() {
        let (view, window) = loader()
        defer { window.isHidden = true }
        #expect(view.isHidden)
        view.setProgress(0.4)
        #expect(!view.isHidden)
        view.setProgress(0)
        #expect(view.isHidden)
        view.startAnimating()
        #expect(!view.isHidden && view.isAnimating)
        view.hidesWhenStopped = false
        #expect(!view.isHidden)
    }

    /// The pull draws its frame; released, the wave loops on from there.
    @Test func aPullDrawsItsFrameAndTheLoopRunsOnFromIt() {
        let (view, window) = loader()
        defer { window.isHidden = true }
        view.setProgress(0.5)
        #expect(isClose(view.debugModelFrame, Timeline.pull(0.5)), "the pull did not draw its frame")
        view.startAnimating()
        #expect(view.debugIsLooping)
        #expect(view.debugAnimationCount == 6, "one loop per pill and lead")
        #expect(isClose(view.debugModelFrame, Timeline.pull(0.5), tolerance: 0.05), "the loop jumped from the pull")
        view.setProgress(0.1)
        #expect(view.debugIsLooping, "a pull scrubbed a loading loader")
        view.stopAnimating()
        #expect(!view.isAnimating && view.debugIsExiting)
    }

    /// ⚠️ DONE, IT FADES WHERE IT IS (the owner, 2026-10-17): the wave keeps
    /// running under the fade.
    @Test func doneFadesThePillsWhereTheyAre() {
        let (view, window) = loader()
        defer { window.isHidden = true }
        view.startAnimating()
        let loops = view.debugAnimationCount
        view.stopAnimating()
        #expect(view.debugIsExiting)
        #expect(view.debugAnimationCount > loops, "the wave stopped instead of fading on")
    }

    /// ⚠️ #580: nothing animates off-window, and the loop comes back with it.
    @Test func itStopsOffWindow() {
        let (view, window) = loader()
        defer { window.isHidden = true }
        view.startAnimating()
        #expect(view.debugAnimationCount > 0)
        view.removeFromSuperview()
        #expect(view.debugAnimationCount == 0, "the loop kept running off-window")
        window.addSubview(view)
        #expect(view.debugAnimationCount > 0, "the loop did not come back")
    }

    /// Reduce Motion: no wave — three dots fading in with the pull, pulsing
    /// while loading.
    @Test func reducedMotionIsThreeStillDots() {
        let (view, window) = loader(reducesMotion: true)
        defer { window.isHidden = true }
        view.setProgress(0.9)
        #expect(isClose(view.debugModelFrame, Timeline.pull(0)), "a reduced-motion pull waved")
        #expect(abs(view.debugOpacity - 0.9) < 0.001)
        view.startAnimating()
        #expect(isClose(view.debugModelFrame, Timeline.pull(0)), "a reduced-motion loader waved")
        #expect(view.debugAnimationCount == 1, "the dots do not pulse")
    }

    /// The pills wear the brand gradient; each lead its tone toward the page,
    /// resolved per appearance.
    @Test func theLeadsResolvePerAppearance() {
        #expect(Palette.loaderTones.count == 3)
        let light = Palette.loaderLeadTones[0].resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = Palette.loaderLeadTones[0].resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        #expect(light != dark, "the lead does not follow the appearance")
        let (view, window) = loader()
        defer { window.isHidden = true }
        view.overrideUserInterfaceStyle = .dark
        view.layoutIfNeeded()
        let expected = dark.cgColor.components ?? []
        let drawn = view.debugTones.leads[0]?.components ?? []
        #expect(expected.count == drawn.count && zip(expected, drawn).allSatisfy { abs($0 - $1) < 0.01 },
                "the lead did not re-resolve for dark: \(drawn) vs \(expected)")
        #expect(view.debugTones.pills[0] == Palette.loaderTones[0].cgColor)
    }

    // MARK: - Pull-to-refresh (#1329 slice 2)

    /// The pull draws the mark out; release plays it on from there; the end
    /// fades it. The indicator is the loader's only driver.
    @Test func thePullToRefreshDrivesTheLoader() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let indicator = HeroPullToRefreshView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        window.addSubview(indicator)
        window.isHidden = false
        defer { window.isHidden = true }
        let loader = indicator.debugLoader
        loader.reducesMotion = { false }

        indicator.setPull(HeroPullToRefreshView.threshold / 2)
        #expect(!loader.isHidden)
        #expect(isClose(loader.debugModelFrame, AppLoaderTimeline.pull(0.5)), "the pull did not draw its frame")

        indicator.setPull(HeroPullToRefreshView.threshold * 2)
        indicator.beginRefreshing()
        #expect(loader.isAnimating && loader.debugIsLooping, "a full pull did not play on from where it was")

        indicator.endRefreshing()
        #expect(!loader.isAnimating && loader.debugIsExiting)
    }

    /// The plain lists' refresh control (#1329 slice 3): the stock spinner
    /// tinted away, the loader following the list's pull, turning when the
    /// control refreshes and closing when it ends.
    @Test func theRefreshControlDrawsTheLoader() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let list = UIScrollView(frame: window.bounds)
        list.contentSize = CGSize(width: 390, height: 2000)
        window.addSubview(list)
        window.isHidden = false
        defer { window.isHidden = true }
        let control = AppRefreshControl()
        list.refreshControl = control
        let loader = control.debugLoader
        loader.reducesMotion = { false }

        #expect(control.tintColor == .clear, "the stock spinner still draws")
        #expect(loader.isHidden)
        list.contentOffset.y = -list.adjustedContentInset.top - HeroPullToRefreshView.threshold / 2
        #expect(!loader.isHidden, "the pull did not draw the mark")

        control.beginRefreshing()
        #expect(loader.isAnimating)
        control.endRefreshing()
        #expect(!loader.isAnimating)
    }

    /// After a refresh, the list folding back is not a pull (#1400): once
    /// the ring's fade is over, nothing shows again until the list is at
    /// rest — or a finger pulls anew.
    @Test func theFoldBackAfterARefreshDrawsNothing() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let indicator = HeroPullToRefreshView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        window.addSubview(indicator)
        window.isHidden = false
        defer { window.isHidden = true }
        let loader = indicator.debugLoader
        loader.reducesMotion = { false }
        indicator.setPull(HeroPullToRefreshView.threshold * 2, isTracking: true)
        indicator.beginRefreshing()
        indicator.endRefreshing()
        // The fade over (the loader back to rest), the list still closing.
        loader.stopAnimating(animated: false)
        for distance in stride(from: HeroPullToRefreshView.threshold, to: 0, by: -10) {
            indicator.setPull(distance)
            #expect(loader.isHidden, "the fold-back drew the loader at \(distance)")
        }
        // A new drag mid-fold-back scrubs again.
        indicator.setPull(HeroPullToRefreshView.threshold / 2, isTracking: true)
        #expect(!loader.isHidden, "a new pull drew nothing")
    }

    /// The same for the plain lists' control: the offset folding back after
    /// `endRefreshing` draws nothing; from rest, a pull draws again.
    @Test func theRefreshControlsFoldBackDrawsNothing() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let list = UIScrollView(frame: window.bounds)
        list.contentSize = CGSize(width: 390, height: 2000)
        window.addSubview(list)
        window.isHidden = false
        defer { window.isHidden = true }
        let control = AppRefreshControl()
        list.refreshControl = control
        let loader = control.debugLoader
        loader.reducesMotion = { false }
        let top = list.adjustedContentInset.top
        control.beginRefreshing()
        control.endRefreshing()
        loader.stopAnimating(animated: false)
        for distance in stride(from: HeroPullToRefreshView.threshold, to: 0, by: -10) {
            list.contentOffset.y = -top - distance
            control.debugFollow(list)
            #expect(loader.isHidden, "the fold-back drew the loader at \(distance)")
        }
        list.contentOffset.y = -top
        control.debugFollow(list)
        list.contentOffset.y = -top - HeroPullToRefreshView.threshold / 2
        control.debugFollow(list)
        #expect(!loader.isHidden, "a pull from rest drew nothing")
    }

    /// Two frames within `tolerance` — the view's model reads back through
    /// layer heights in points.
    private func isClose(
        _ a: AppLoaderTimeline.Frame, _ b: AppLoaderTimeline.Frame, tolerance: CGFloat = 0.001
    ) -> Bool {
        guard a.heights.count == b.heights.count, a.leadHeights.count == b.leadHeights.count else { return false }
        for (lhs, rhs) in zip(a.heights + a.leadHeights, b.heights + b.leadHeights) where abs(lhs - rhs) >= tolerance {
            return false
        }
        return true
    }

}


/// The tick a pull gives as it crosses its threshold (#1354): once per
/// crossing, under a finger only.
@MainActor
struct PullThresholdFeedbackTests {
    @Test func ticksOncePerCrossingUnderAFinger() {
        let feedback = PullThresholdFeedback()
        #expect(!feedback.update(pulled: 60, threshold: 120, isTracking: true))
        #expect(feedback.update(pulled: 125, threshold: 120, isTracking: true), "crossing did not tick")
        #expect(!feedback.update(pulled: 160, threshold: 120, isTracking: true), "holding past it ticked again")
        #expect(!feedback.update(pulled: 100, threshold: 120, isTracking: true))
        #expect(feedback.update(pulled: 130, threshold: 120, isTracking: true), "a second crossing did not tick")
    }

    @Test func aDriftWithoutAFingerSaysNothing() {
        let feedback = PullThresholdFeedback()
        #expect(!feedback.update(pulled: 140, threshold: 120, isTracking: false), "a bounce-back ticked")
        #expect(!feedback.isArmed)
    }

    /// Both indicators wear it.
    @Test func bothRefreshIndicatorsTick() {
        let hero = HeroPullToRefreshView()
        hero.setPull(HeroPullToRefreshView.threshold + 4, isTracking: true)
        #expect(hero.debugThresholdFeedback.isArmed)
        hero.setPull(10, isTracking: true)
        #expect(!hero.debugThresholdFeedback.isArmed)

        let control = AppRefreshControl()
        #expect(!control.debugThresholdFeedback.isArmed)
    }
}
