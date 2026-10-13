import DesignSystem
import Foundation
import Testing
import UIKit
@testable import EmoteKit

/// The arrival over the skeleton (#1071), on every surface that shows one: a
/// label's emote, the composer's, a panel or strip tile. The art bounces in —
/// the keyboard's own arrival (#731) — while the skeleton fades and shrinks
/// out from under it, both in the same frame; nothing at all when no skeleton
/// was shown, under a motion gate, or after a failed load; and a place given
/// up mid-way ends at rest.
///
/// ⚠️ THE ARRIVAL IS READ FROM THE LAYERS, PARKED. Each window runs at layer
/// speed 0 (`freeze`) while the art lands, so the half-second spring is still
/// on its layer whenever the test looks — on a starved runner as on a fast
/// Mac. Its clock is parked at a known, non-zero time, so a begin time the
/// arrival set itself reads as that time, and one left to the commit reads
/// zero. The speed is the test window's own, never process-wide.
///
/// ⚠️ THE ART ARRIVES ON THE TEST'S CLOCK (`ArtGate`), never the bake queue's.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteRevealTests {
    private let font = UIFont.systemFont(ofSize: 17)

    enum Surface: String, CaseIterable, CustomTestStringConvertible {
        case label, composer, tile
        var testDescription: String { rawValue }
    }

    /// One emote place: its skeleton, its art's view, and what hosts both.
    private struct Place {
        let skeleton: EmoteSkeleton
        let art: () -> UIView?
        /// The view the skeleton's bone lives in.
        let host: UIView
        let window: UIWindow
        /// Whether the art (not the glyph) holds the square.
        let showsArt: () -> Bool
        /// Whether the system glyph holds the square.
        let showsGlyph: () -> Bool
        /// Gives the place up, as a reuse or an edit does.
        let giveUp: () -> Void
    }

    private func gatedEngine(_ gate: ArtGate, answers: Bool = true) -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil, animationProvider: { _ in nil })
        engine.artProvider = { _, side, _ in
            await gate.wait()
            return answers ? EmoteLabelTests.syntheticArt(side: side) : nil
        }
        engine.skeletonConditions = { EmoteSkeleton.Conditions() }
        return engine
    }

    private func makeWindow(_ side: CGFloat) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: side, height: side))
        window.isHidden = false
        return window
    }

    /// The place on `surface`, its emote asked for from `engine`.
    private func makePlace(_ surface: Surface, engine: EmoteEngine, emote id: String = "noto:1f525") async throws -> Place {
        let emote = try #require(EmoteCatalog.shared.emote(id: id))
        switch surface {
        case .label:
            let window = makeWindow(400)
            let label = EmoteLabel()
            label.engine = engine
            label.font = font
            label.textColor = .black
            label.setEmoteText("so \(emote.glyph) good")
            window.addSubview(label)
            label.frame = CGRect(x: 10, y: 10, width: 320, height: 40)
            label.layoutIfNeeded()
            let player = try #require(label.artViews.first, "the label placed no emote")
            // The skeleton belongs to the player; the label lists only those on show.
            let skeleton = try #require(label.placeSkeletons.first)
            return Place(
                skeleton: skeleton, art: { player }, host: label, window: window,
                showsArt: { label.showingEmoteCount + label.posterEmoteCount == 1 },
                showsGlyph: { label.coveredMarkIndices.isEmpty },
                giveUp: {
                    label.setEmoteText("only words now")
                    label.layoutIfNeeded()
                }
            )
        case .composer:
            let window = makeWindow(500)
            let field = EmoteTextView(engine: engine)
            field.font = font
            field.frame = CGRect(x: 10, y: 10, width: 300, height: 300)
            window.addSubview(field)
            field.plainText = "so \(emote.glyph)"
            field.layoutIfNeeded()
            try #require(await settle { field.emoteViews.count == 1 })
            let view = try #require(field.emoteViews.first)
            return Place(
                skeleton: view.skeleton, art: { view.artView }, host: view, window: window,
                showsArt: { view.isShowingArt || view.showsPosterArt }, showsGlyph: { view.showsStill },
                giveUp: {
                    field.plainText = ""
                    field.layoutIfNeeded()
                    // TextKit may keep the view a turn; leaving the window is the give-up.
                    view.removeFromSuperview()
                }
            )
        case .tile:
            let window = makeWindow(200)
            let tile = EmoteTileView(frame: CGRect(x: 20, y: 20, width: 44, height: 44))
            window.addSubview(tile)
            tile.layoutIfNeeded()
            tile.configure(emote, engine: engine, prefersAnimation: true)
            return Place(
                skeleton: tile.skeleton, art: { tile.player }, host: tile, window: window,
                showsArt: { tile.isShowingArt }, showsGlyph: { tile.showsGlyph },
                giveUp: { tile.reset() }
            )
        }
    }

    /// The time a frozen window's clock is parked at.
    private static let parkedTime: CFTimeInterval = 1_000

    /// Parks every animation in `window` where it is, its clock at `parkedTime`.
    private func freeze(_ window: UIWindow) {
        window.layer.speed = 0
        window.layer.timeOffset = Self.parkedTime
    }

    private func bones(in view: UIView) -> [SkeletonBoneView] {
        view.subviews.compactMap { $0 as? SkeletonBoneView }
    }

    private func scale(_ value: Any?) -> CGFloat? {
        guard let value = value as? NSValue else { return nil }
        let transform = value.caTransform3DValue
        return transform.m11
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// The opacity a fade runs from and to, as drawn: a nil end is the model's.
    private func effective(_ fade: CABasicAnimation, model: Double) -> (from: Double?, to: Double?) {
        (number(fade.fromValue) ?? model, number(fade.toValue) ?? model)
    }

    /// The scale a transform animation runs from and to, as drawn: an
    /// additive one is relative to the model; a nil end is the model's.
    private func effective(_ animation: CABasicAnimation, model: CATransform3D) -> (from: CGFloat?, to: CGFloat?) {
        let base: CGFloat = animation.isAdditive ? model.m11 : 1
        let from = animation.fromValue == nil ? model.m11 : scale(animation.fromValue).map { $0 * base }
        let to = animation.toValue == nil ? model.m11 : scale(animation.toValue).map { $0 * base }
        return (from, to)
    }

    /// Whether `view` is at rest: full alpha, its own size, nothing animating.
    private func atRest(_ view: UIView) -> Bool {
        view.alpha == 1 && view.transform == .identity && (view.layer.animationKeys() ?? []).isEmpty
    }

    // MARK: - The arrival

    /// THE HAND-OFF, on every surface: the art fades and bounces in from a
    /// third of its size on the keyboard's spring, the skeleton fades and
    /// shrinks out, and both begin at the same instant on the same square.
    @Test(arguments: Surface.allCases)
    func theArtBouncesInAsTheSkeletonFadesAndShrinksOutTogether(_ surface: Surface) async throws {
        let gate = ArtGate()
        defer { gate.open() }
        // A tile holds its engine weakly: the test keeps it.
        let engine = gatedEngine(gate)
        let place = try await makePlace(surface, engine: engine)
        defer { place.window.isHidden = true }
        try #require(place.skeleton.isShowing, "no skeleton for art on its way")
        let square = place.skeleton.frame
        freeze(place.window)

        gate.open()
        try #require(await settle { place.skeleton.revealCount == 1 }, "the art never arrived over its skeleton")
        let art = try #require(place.art())
        let bone = try #require(place.skeleton.leavingBone, "the skeleton left without its fade")
        #expect(place.showsArt())
        #expect(!place.skeleton.isShowing)
        // Frames are model values, and the leaving skeleton's model is already
        // shrunk: the square is its centre and its untransformed size.
        #expect(art.center == CGPoint(x: square.midX, y: square.midY) && art.bounds.size == square.size,
                "the art is not the skeleton's square: \(art.frame) vs \(square)")
        #expect(bone.center == CGPoint(x: square.midX, y: square.midY) && bone.bounds.size == square.size,
                "the skeleton moved: \(bone.center) \(bone.bounds) vs \(square)")
        #expect(bone.superview === place.host && art.superview === place.host)

        let artKeys = art.layer.animationKeys() ?? []
        let boneKeys = bone.layer.animationKeys() ?? []
        let artFade = try #require(art.layer.animation(forKey: EmoteSkeleton.Arrival.fadeKey) as? CASpringAnimation, "art: \(artKeys)")
        let artBounce = try #require(art.layer.animation(forKey: EmoteSkeleton.Arrival.bounceKey) as? CASpringAnimation, "art: \(artKeys)")
        let boneFade = try #require(bone.layer.animation(forKey: EmoteSkeleton.Arrival.skeletonFadeKey) as? CABasicAnimation, "skeleton: \(boneKeys)")
        let boneShrink = try #require(bone.layer.animation(forKey: EmoteSkeleton.Arrival.skeletonShrinkKey) as? CABasicAnimation, "skeleton: \(boneKeys)")

        // The art: from nothing and a third of its size, past it and back.
        // Read as drawn: a nil end is the model's, an additive value is
        // relative to it.
        #expect(number(artFade.fromValue) == 0 && effective(artFade, model: Double(art.layer.opacity)).to == 1,
                "art fade \(String(describing: artFade.fromValue)) → \(String(describing: artFade.toValue))")
        let bounce = effective(artBounce, model: art.layer.transform)
        #expect(bounce.from.map { abs($0 - EmoteSkeleton.Arrival.fromScale) < 0.001 } == true, "bounce from \(String(describing: bounce.from))")
        #expect(bounce.to == 1, "bounce to \(String(describing: bounce.to))")
        #expect(artBounce.damping > 0 && artBounce.damping < 2 * (artBounce.stiffness * artBounce.mass).squareRoot(),
                "the spring is not under-damped: it never passes the emote's size")
        // The skeleton: to nothing, a little smaller, around its centre.
        #expect(number(boneFade.fromValue) == 1 && effective(boneFade, model: Double(bone.layer.opacity)).to == 0,
                "skeleton fade \(String(describing: boneFade.fromValue)) → \(String(describing: boneFade.toValue))")
        let shrink = effective(boneShrink, model: bone.layer.transform)
        #expect(shrink.from.map { abs($0 - 1) < 0.001 } == true, "skeleton shrink from \(String(describing: shrink.from))")
        #expect(shrink.to.map { abs($0 - EmoteSkeleton.leavingScale) < 0.001 } == true,
                "skeleton shrink to \(String(describing: shrink.to))")
        #expect(bone.layer.anchorPoint == CGPoint(x: 0.5, y: 0.5) && art.layer.anchorPoint == CGPoint(x: 0.5, y: 0.5))

        // Together: one explicit begin time, the host's now — not left to the
        // commit.
        let begins = [artFade.beginTime, artBounce.beginTime, boneFade.beginTime, boneShrink.beginTime]
        #expect(Set(begins).count == 1, "the halves begin apart: \(begins)")
        #expect(begins.first == Self.parkedTime, "the begin time is not the host's now: \(begins)")
        // And both end.
        for animation in [artFade, artBounce, boneFade, boneShrink] as [CAAnimation] {
            #expect(animation.repeatCount == 0 && animation.duration > 0 && animation.duration <= 1)
        }
    }

    /// Both halves END: the skeleton leaves the hierarchy, and the art is left
    /// at rest — full alpha, its own size, no animation on its layer.
    @Test(arguments: Surface.allCases)
    func theArrivalEndsAtRest(_ surface: Surface) async throws {
        let gate = ArtGate()
        defer { gate.open() }
        // A tile holds its engine weakly: the test keeps it.
        let engine = gatedEngine(gate)
        let place = try await makePlace(surface, engine: engine)
        defer { place.window.isHidden = true }
        try #require(place.skeleton.isShowing)
        gate.open()
        try #require(await settle { place.skeleton.revealCount == 1 }, "the art never arrived over its skeleton")
        let art = try #require(place.art())
        #expect(await settle { !place.skeleton.isRevealing && bones(in: place.host).isEmpty },
                "the arrival never ended")
        #expect(atRest(art), "alpha \(art.alpha), transform \(art.transform), \(art.layer.animationKeys() ?? [])")
    }

    // MARK: - No arrival

    /// Art in memory installs in the layout pass, with no skeleton and no
    /// bounce, on any surface.
    @Test(arguments: Surface.allCases)
    func artInMemoryArrivesWithNoBounce(_ surface: Surface) async throws {
        let engine = EmoteEngine(diskCache: nil, animationProvider: { _ in nil })
        engine.skeletonConditions = { EmoteSkeleton.Conditions() }
        let fire = try #require(EmoteCatalog.shared.emote(id: "noto:1f525"))
        for side in EmoteEngine.pixelBuckets {
            engine.insert(EmoteLabelTests.syntheticArt(side: side), for: fire, pixelSide: side, motion: .loop)
        }
        let place = try await makePlace(surface, engine: engine)
        defer { place.window.isHidden = true }
        try #require(await settle { place.showsArt() })
        let art = try #require(place.art())
        #expect(place.skeleton.revealCount == 0)
        #expect(atRest(art), "art in memory bounced in: \(art.layer.animationKeys() ?? [])")
    }

    /// Art READ before the skeleton's grace was up (a bundled seed) lands
    /// plain: no skeleton showed, so there is nothing to hand over.
    @Test(arguments: [Surface.label, .tile])
    func artReadBeforeTheSkeletonArrivesWithNoBounce(_ surface: Surface) async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let engine = EmoteEngine(diskCache: nil, seeds: .bundled, animationProvider: { _ in nil })
        engine.artProvider = { _, side, _ in
            await gate.wait()
            return EmoteLabelTests.syntheticArt(side: side)
        }
        engine.skeletonConditions = { EmoteSkeleton.Conditions() }
        engine.localArtGrace = 600
        // 😂 is seeded: a read, so its skeleton waits out the grace.
        let place = try await makePlace(surface, engine: engine, emote: "noto:1f602")
        defer { place.window.isHidden = true }
        try #require(!place.skeleton.isShowing && place.skeleton.isScheduled, "not a read: \(surface)")
        freeze(place.window)
        gate.open()
        try #require(await settle { place.showsArt() }, "the read never landed")
        let art = try #require(place.art())
        #expect(place.skeleton.revealCount == 0)
        #expect(!place.skeleton.isScheduled, "the skeleton still waits for art that is on show")
        #expect(atRest(art), "art read at once bounced in: \(art.layer.animationKeys() ?? [])")
        #expect(bones(in: place.host).isEmpty)
    }

    enum Gate: String, CaseIterable, CustomTestStringConvertible {
        case reduceMotion, powerSaving, idleCalm
        var conditions: EmoteSkeleton.Conditions {
            switch self {
            case .reduceMotion: EmoteSkeleton.Conditions(reducesMotion: true)
            case .powerSaving: EmoteSkeleton.Conditions(powerSaving: true)
            case .idleCalm: EmoteSkeleton.Conditions(idleCalm: true)
            }
        }
        var testDescription: String { rawValue }
    }

    /// Under each of the shimmer's gates the art takes the square at once and
    /// the skeleton goes with it: a straight swap — no scale, no bounce, no
    /// fade — on every surface.
    @Test(arguments: Gate.allCases)
    func underEachGateTheArtSwapsInWithNoBounce(_ gate: Gate) async throws {
        for surface in Surface.allCases {
            let art = ArtGate()
            defer { art.open() }
            let engine = gatedEngine(art)
            engine.skeletonConditions = { gate.conditions }
            let place = try await makePlace(surface, engine: engine)
            defer { place.window.isHidden = true }
            try #require(place.skeleton.isShowing, "\(surface): no skeleton")
            freeze(place.window)
            art.open()
            try #require(await settle { place.showsArt() }, "\(surface): the art never came")
            let view = try #require(place.art())
            #expect(place.skeleton.revealCount == 0, "\(surface): an arrival under \(gate)")
            #expect(atRest(view), "\(surface) under \(gate): \(view.layer.animationKeys() ?? [])")
            #expect(bones(in: place.host).isEmpty, "\(surface) under \(gate): the skeleton lingered")
        }
    }

    /// A failed load falls back to the glyph with no bounce and no scale: the
    /// skeleton only fades.
    @Test(arguments: Surface.allCases)
    func aFailedLoadFallsBackWithNoBounce(_ surface: Surface) async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let engine = gatedEngine(gate, answers: false)
        let place = try await makePlace(surface, engine: engine)
        defer { place.window.isHidden = true }
        try #require(place.skeleton.isShowing)
        freeze(place.window)
        gate.open()
        try #require(await settle { place.showsGlyph() }, "no glyph after a failed load")
        #expect(place.skeleton.revealCount == 0)
        #expect(!place.showsArt())
        if let art = place.art() {
            #expect(atRest(art), "the art's view animates after a failed load: \(art.layer.animationKeys() ?? [])")
        }
        for bone in bones(in: place.host) {
            #expect(bone.layer.animation(forKey: EmoteSkeleton.Arrival.skeletonShrinkKey) == nil && bone.transform == .identity, "the failed skeleton scales")
        }
    }

    // MARK: - Reuse

    /// A place given up MID-ARRIVAL — a tile reused, a label edited, the
    /// composer's emote deleted — ends it at once: the art at rest, the
    /// skeleton gone, nothing in flight.
    @Test(arguments: Surface.allCases)
    func givenUpMidArrivalThePlaceEndsAtRest(_ surface: Surface) async throws {
        let gate = ArtGate()
        defer { gate.open() }
        // A tile holds its engine weakly: the test keeps it.
        let engine = gatedEngine(gate)
        let place = try await makePlace(surface, engine: engine)
        defer { place.window.isHidden = true }
        try #require(place.skeleton.isShowing)
        freeze(place.window)
        gate.open()
        try #require(await settle { place.skeleton.revealCount == 1 })
        let art = try #require(place.art())
        try #require(place.skeleton.isRevealing && !bones(in: place.host).isEmpty, "not mid-arrival")
        try #require(art.layer.animation(forKey: EmoteSkeleton.Arrival.bounceKey) != nil, "not mid-bounce")

        place.giveUp()
        #expect(!place.skeleton.isRevealing)
        #expect(!place.skeleton.isShowing)
        #expect(bones(in: place.host).isEmpty, "\(surface): a skeleton outlived its place")
        #expect(atRest(art), "\(surface): alpha \(art.alpha), transform \(art.transform), \(art.layer.animationKeys() ?? [])")
    }

    /// A reused TILE dressed again at once (art in memory) is at rest from
    /// its first frame: nothing of the arrival it was in carries over.
    @Test func aTileReusedMidArrivalAndDressedAgainIsAtRest() async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let engine = gatedEngine(gate)
        let cool = try #require(EmoteCatalog.shared.emote(id: "noto:1f60e"))
        engine.insert(EmoteLabelTests.syntheticArt(side: EmoteTileView.pixelSide), for: cool,
                      pixelSide: EmoteTileView.pixelSide, motion: .loop)
        let place = try await makePlace(.tile, engine: engine)
        defer { place.window.isHidden = true }
        let tile = try #require(place.host as? EmoteTileView)
        freeze(place.window)
        gate.open()
        try #require(await settle { tile.skeleton.isRevealing })

        tile.configure(cool, engine: engine, prefersAnimation: true)
        #expect(tile.isShowingArt)
        #expect(!tile.skeleton.isRevealing && bones(in: tile).isEmpty)
        #expect(atRest(tile.player), "\(tile.player.layer.animationKeys() ?? [])")
    }

    // MARK: - The keyboard's bounce

    /// THE SAME ANIMATION AS THE KEYBOARD'S (#731), now everywhere: the
    /// arrival's springs are what UIKit built for the tile's old
    /// `UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping:
    /// 0.55, initialSpringVelocity: 0.6)` from alpha 0 and a third of the size.
    @Test func theArrivalIsTheKeyboardsBounce() throws {
        let window = makeWindow(100)
        defer { window.isHidden = true }
        let view = UIView(frame: CGRect(x: 10, y: 10, width: 40, height: 40))
        window.addSubview(view)
        view.alpha = 0
        view.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.55,
                       initialSpringVelocity: 0.6, options: [.allowUserInteraction]) {
            view.alpha = 1
            view.transform = .identity
        }
        let uikit = try #require(view.layer.animation(forKey: "transform") as? CASpringAnimation)
        let uikitFade = try #require(view.layer.animation(forKey: "opacity") as? CASpringAnimation)
        let ours = EmoteSkeleton.Arrival.spring(
            "transform", from: CATransform3DMakeScale(0.3, 0.3, 1), to: CATransform3DIdentity, begin: 0
        )
        for theirs in [uikit, uikitFade] {
            #expect(abs(ours.mass - theirs.mass) < 1e-9)
            #expect(abs(ours.stiffness - theirs.stiffness) < 1e-6, "stiffness \(theirs.stiffness)")
            #expect(abs(ours.damping - theirs.damping) < 1e-6, "damping \(theirs.damping)")
            #expect(abs(ours.initialVelocity - theirs.initialVelocity) < 1e-9)
            #expect(ours.duration == theirs.duration)
        }
        #expect(abs(EmoteSkeleton.Arrival.fromScale - 0.3) < 1e-9)
        view.layer.removeAllAnimations()
    }
}
