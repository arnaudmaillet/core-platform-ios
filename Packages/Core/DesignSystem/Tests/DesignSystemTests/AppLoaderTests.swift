import CoreGraphics
import Testing
import UIKit
@testable import DesignSystem

/// The branded loader (#1329): its three forms' outlines, the pull's frames,
/// the loop's seam, and the view's lifecycle rules.
@MainActor
struct AppLoaderTests {
    private typealias Geometry = AppLoaderGeometry
    private typealias Timeline = AppLoaderTimeline

    nonisolated private static let pieces = 0..<4

    private static func forms(_ piece: Int) -> [(String, [CGPoint])] {
        [("square", Geometry.square(piece)), ("disc", Geometry.disc(piece)), ("ring", Geometry.restingRing(piece))]
    }

    private static func reach(_ point: CGPoint, along angle: CGFloat) -> CGFloat {
        (point.x - 0.5) * cos(angle) + (point.y - 0.5) * sin(angle)
    }

    // MARK: - Outlines

    /// ⚠️ ONE STRUCTURE IN EVERY FORM: the same point count, clockwise on
    /// screen, starting at the point furthest along the piece's diagonal —
    /// or a morph between two forms twists.
    @Test(arguments: 0..<4)
    func everyFormSharesOneOutlineStructure(_ piece: Int) {
        let diagonal = (-135 + 90 * CGFloat(piece)) * .pi / 180
        for (name, outline) in Self.forms(piece) {
            #expect(outline.count == Geometry.pointCount, "\(name) \(piece): \(outline.count) points")
            #expect(Geometry.signedArea(outline) > 0, "\(name) \(piece) runs anticlockwise")
            let furthest = outline.map { Self.reach($0, along: diagonal) }.max() ?? 0
            #expect(Self.reach(outline[0], along: diagonal) > furthest - 0.01,
                    "\(name) \(piece) does not start at its diagonal's extreme")
        }
    }

    /// Each piece stays on its own quadrant in every form: its centroid lies
    /// on its diagonal's side of both axes, so no piece swaps place.
    @Test(arguments: 0..<4)
    func everyPieceKeepsItsQuadrant(_ piece: Int) {
        let signX: CGFloat = piece == 0 || piece == 3 ? -1 : 1
        let signY: CGFloat = piece < 2 ? -1 : 1
        for (name, outline) in Self.forms(piece) {
            let c = Geometry.centroid(outline)
            #expect((c.x - 0.5) * signX > 0 && (c.y - 0.5) * signY > 0, "\(name) \(piece) left its quadrant: \(c)")
        }
    }

    /// The square's pills keep the cut gap between neighbours.
    @Test func theSquaresPiecesKeepTheGap() {
        let gap = minimumDistance(Geometry.square(0), Geometry.square(1))
        #expect(abs(gap - Geometry.gap) < 0.003, "TL–TR gap \(gap)")
        let across = minimumDistance(Geometry.square(1), Geometry.square(2))
        #expect(abs(across - Geometry.gap) < 0.003, "TR–BR gap \(across)")
    }

    /// The ring's caps stand the square's gap apart, whatever the fractions.
    @Test func theRingsCapGapIsConstant() {
        for fractions in [Geometry.equalQuarters] + Timeline.loopFractions().prefix(20) {
            let ring = Geometry.ring(fractions: fractions)
            for piece in Self.pieces {
                let gap = minimumDistance(ring[piece], ring[(piece + 1) % Geometry.pieceCount])
                #expect(abs(gap - Geometry.gap) < 0.004, "gap \(gap) after piece \(piece) at \(fractions)")
            }
        }
    }

    /// Everything stays inside the loader's square.
    @Test(arguments: 0..<4)
    func noFormLeavesTheSquare(_ piece: Int) {
        for (name, outline) in Self.forms(piece) {
            #expect(outline.allSatisfy { (-0.001...1.001).contains($0.x) && (-0.001...1.001).contains($0.y) }, "\(name) \(piece)")
        }
    }

    // MARK: - The pull

    /// The same finger position always draws the same frame, whatever came
    /// before — pulling back plays the pull in reverse.
    @Test func thePullIsReproducible() {
        for p in stride(from: CGFloat(0), through: 1, by: 0.05) {
            #expect(Timeline.pull(p) == Timeline.pull(p))
        }
        #expect(Timeline.pull(-1) == Timeline.pull(0))
        #expect(Timeline.pull(3) == Timeline.pull(1))
    }

    /// The pills appear one after another, clockwise from the pink; the mark
    /// is still until ≈0.35 and half a turn round at the threshold, a ring.
    @Test func thePullAppearsMorphsAndTurns() {
        #expect(Timeline.pull(0).opacities == [0, 0, 0, 0])
        let early = Timeline.pull(0.08).opacities
        #expect(early[0] > early[1] && early[1] > early[2] && early[2] >= early[3], "not clockwise: \(early)")
        #expect(Timeline.pull(Timeline.appearEnd).opacities == [1, 1, 1, 1])
        #expect(Timeline.pull(Timeline.appearEnd).outlines[0] == Geometry.square(0))
        #expect(Timeline.pull(Timeline.discAt).outlines[0] == Geometry.disc(0))
        #expect(Timeline.pull(0.3).rotation == 0)
        #expect(abs(Timeline.pull(1).rotation - .pi) < 0.0001)
        #expect(Timeline.pull(1).outlines[2] == Geometry.restingRing(2))
    }

    // MARK: - The loop

    /// Seeded: the same seed draws the same loop, another seed another one.
    @Test func theLoopIsSeeded() {
        #expect(Timeline.loopFractions(seed: 7) == Timeline.loopFractions(seed: 7))
        #expect(Timeline.loopFractions(seed: 7) != Timeline.loopFractions(seed: 8))
    }

    /// ⚠️ NO SEAM: the loop opens and closes on equal quarters over a whole
    /// number of turns, every arc keeps a minimum share, and the four always
    /// make the whole ring.
    @Test func theLoopHasNoSeam() {
        let frames = Timeline.loopFractions()
        #expect(frames.first == Geometry.equalQuarters)
        #expect(frames.last == Geometry.equalQuarters)
        #expect(Timeline.turnsPerLoop == Timeline.turnsPerLoop.rounded() && Timeline.turnsPerLoop >= 1)
        for fractions in frames {
            #expect(abs(fractions.reduce(0, +) - 1) < 0.0001)
            #expect(fractions.allSatisfy { $0 >= Timeline.minimumFraction - 0.0001 }, "\(fractions)")
        }
        #expect(Set(frames.map { $0.map { ($0 * 1000).rounded() } }).count > 4, "the arcs never traded length")
    }

    /// The loop's rest is exactly where the pull ends, so release does not jump.
    @Test func theLoopStartsWhereThePullEnds() {
        let loop = Timeline.loopKeyframes()
        for piece in Self.pieces {
            #expect(loop[piece].first == Timeline.pull(1).outlines[piece])
            #expect(loop[piece].first == loop[piece].last)
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

    /// From a full pull the ring turns at once from the pull's angle; the
    /// scrub no longer drives it while loading.
    @Test func aFullPullLoopsFromItsAngle() {
        let (view, window) = loader()
        defer { window.isHidden = true }
        view.setProgress(1)
        view.startAnimating()
        #expect(view.debugIsLooping)
        #expect(abs(view.debugModelFrame.rotation - .pi) < 0.001)
        view.setProgress(0.2)
        #expect(abs(view.debugModelFrame.rotation - .pi) < 0.001, "a pull scrubbed a loading loader")
        view.stopAnimating()
        #expect(!view.isAnimating && view.debugIsExiting)
    }

    /// ⚠️ DONE, IT FADES WHERE IT IS, STILL TURNING (the owner, 2026-10-17):
    /// no closing back into the square, which outlived the load on device —
    /// the loop keeps running under the fade, and the model stays the ring.
    @Test func doneFadesTheRingWhereItIs() {
        let (view, window) = loader()
        defer { window.isHidden = true }
        view.setProgress(1)
        view.startAnimating()
        let loops = view.debugAnimationCount
        view.stopAnimating()
        #expect(view.debugIsExiting)
        #expect(view.debugAnimationCount > loops, "the loop stopped instead of fading on")
        #expect(isClose(view.debugModelFrame, AppLoaderTimeline.pull(1)), "it closed back into the square")
    }

    /// ⚠️ #580: nothing animates off-window, and the loop comes back with it.
    @Test func itStopsOffWindow() {
        let (view, window) = loader()
        defer { window.isHidden = true }
        view.setProgress(1)
        view.startAnimating()
        #expect(view.debugAnimationCount > 0)
        view.removeFromSuperview()
        #expect(view.debugAnimationCount == 0, "the loop kept running off-window")
        window.addSubview(view)
        #expect(view.debugAnimationCount > 0, "the loop did not come back")
    }

    /// Reduce Motion: no morph and no turn — the square, upright, fading in
    /// with the pull.
    @Test func reducedMotionIsTheStillSquare() {
        let (view, window) = loader(reducesMotion: true)
        defer { window.isHidden = true }
        view.setProgress(0.9)
        let frame = view.debugModelFrame
        #expect(frame.rotation == 0)
        #expect(frame.opacities.allSatisfy { abs($0 - 0.9) < 0.001 })
        for piece in Self.pieces {
            let still = AppLoaderTimeline.Frame(
                outlines: [Geometry.square(piece)], opacities: [frame.opacities[piece]], rotation: 0
            )
            #expect(isClose(AppLoaderTimeline.Frame(
                outlines: [frame.outlines[piece]], opacities: [frame.opacities[piece]], rotation: 0
            ), still))
        }
    }

    // MARK: - Pull-to-refresh (#1329 slice 2)

    /// The pull draws the mark out; release turns it on from there; the end
    /// closes it. The indicator is the loader's only driver.
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
        #expect(loader.isAnimating && loader.debugIsLooping, "a full pull did not turn on from where it was")

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

    /// Two frames within float noise — the view's model reads back through a
    /// path in points.
    private func isClose(_ a: AppLoaderTimeline.Frame, _ b: AppLoaderTimeline.Frame) -> Bool {
        guard a.outlines.count == b.outlines.count, abs(a.rotation - b.rotation) < 0.0001 else { return false }
        for (lhs, rhs) in zip(a.opacities, b.opacities) where abs(lhs - rhs) >= 0.001 { return false }
        for (lhs, rhs) in zip(a.outlines, b.outlines) {
            guard lhs.count == rhs.count else { return false }
            for (p, q) in zip(lhs, rhs) {
                let dx: CGFloat = abs(p.x - q.x)
                let dy: CGFloat = abs(p.y - q.y)
                if dx >= 0.0001 || dy >= 0.0001 { return false }
            }
        }
        return true
    }

    private func minimumDistance(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for p in a { for q in b { best = min(best, hypot(p.x - q.x, p.y - q.y)) } }
        return best
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
