import CacheKit
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The square skeleton that holds an animated emote's place until its art
/// lands (#987), on every surface: a label's emote, the composer's, a panel
/// or strip tile. Skeleton while pending, the art in its exact square on
/// arrival, the glyph on failure, a still shimmer under each motion gate, and
/// none at all for art that is seeded or cached.
///
/// ⚠️ THE ART ARRIVES ON THE TEST'S CLOCK (`ArtGate`), never the bake queue's:
/// that queue is one serial queue for the whole process, and on a starved CI
/// runner a bake waited behind every parallel suite's for minutes.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteSkeletonTests {
    private let font = UIFont.systemFont(ofSize: 17)
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("emote-skeleton-\(UUID().uuidString)", isDirectory: true)

    /// A cold engine (no disk, no seeds) whose art waits for `gate`, then is
    /// `art` — or nil, for a failed load.
    private func gatedEngine(_ gate: ArtGate, answers: Bool = true) -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil, animationProvider: { _ in nil })
        engine.artProvider = { _, side, _ in
            await gate.wait()
            return answers ? EmoteLabelTests.syntheticArt(side: side) : nil
        }
        return engine
    }

    private func hostedLabel(_ text: String, engine: EmoteEngine) -> (EmoteLabel, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false
        let label = EmoteLabel()
        label.engine = engine
        label.font = font
        label.textColor = .black
        label.numberOfLines = 0
        label.setEmoteText(text)
        window.addSubview(label)
        let size = label.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        label.frame = CGRect(x: 10, y: 10, width: 320, height: size.height)
        label.layoutIfNeeded()
        return (label, window)
    }

    private func hostedTile() -> (EmoteTileView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        let tile = EmoteTileView(frame: CGRect(x: 20, y: 20, width: 44, height: 44))
        window.addSubview(tile)
        tile.layoutIfNeeded()
        return (tile, window)
    }

    private func hostedField(_ text: String, engine: EmoteEngine) -> (EmoteTextView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        window.isHidden = false
        let field = EmoteTextView(engine: engine)
        field.font = font
        field.frame = CGRect(x: 10, y: 10, width: 300, height: 400)
        window.addSubview(field)
        field.plainText = text
        field.layoutIfNeeded()
        return (field, window)
    }

    private func emote(_ id: String) throws -> Emote {
        try #require(EmoteCatalog.shared.emote(id: id))
    }

    /// Whether a skeleton bone is still in `view`'s subviews (one fading out
    /// included).
    private func holdsABone(_ view: UIView) -> Bool {
        view.subviews.contains { $0 is SkeletonBoneView }
    }

    // MARK: - Pending, arrival, failure: labels

    /// A label's emote whose art must be baked: a skeleton in the emote's
    /// square at once, and no glyph under it.
    @Test func aLabelShowsASkeletonWhileTheArtIsPending() throws {
        let gate = ArtGate()
        defer { gate.open() }
        let (label, window) = hostedLabel("so 🔥 good", engine: gatedEngine(gate))
        defer { window.isHidden = true }
        #expect(label.skeletonCount == 1, "no skeleton for art on its way")
        let skeleton = try #require(label.skeletons.first)
        let square = try #require(label.emoteFrames.first)
        #expect(skeleton.frame == square, "the skeleton is not the emote's square")
        #expect(abs(square.width - square.height) < 0.01, "not a square: \(square)")
        #expect(skeleton.boneView?.layer.cornerRadius ?? 0 < square.width / 3, "a disc, not a square")
        #expect(label.coveredMarkIndices == [0], "the glyph is drawn under the skeleton")
        #expect(EmoteLabelTests.colouredInk(of: label) == nil, "a glyph under the skeleton")
    }

    /// The art lands in the skeleton's exact square: the label keeps its size,
    /// the player takes the frame the skeleton had, and the glyph is not drawn
    /// at any point between.
    @Test func aLabelSwapsTheSkeletonForTheArtInTheSameSquare() async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let (label, window) = hostedLabel("a 🔥 b 😎 and words to wrap onto a second line", engine: gatedEngine(gate))
        defer { window.isHidden = true }
        try #require(label.skeletonCount == 2)
        let skeletonFrames = label.skeletons.map(\.frame)
        let bounds = label.bounds
        let fitted = label.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))

        gate.open()
        var glyphSeen = false
        let landed = await settle {
            label.layoutIfNeeded()
            if label.coveredMarkIndices != [0, 1] { glyphSeen = true }
            return label.showingEmoteCount == 2
        }
        try #require(landed, "the art never came")
        #expect(!glyphSeen, "a glyph showed between the skeleton and the art")
        #expect(label.skeletonCount == 0)
        #expect(label.emoteFrames == skeletonFrames, "the art moved: \(label.emoteFrames) vs \(skeletonFrames)")
        #expect(label.bounds == bounds)
        #expect(label.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)) == fitted)
        #expect(EmoteLabelTests.colouredInk(of: label) == nil)
        // The skeleton fades out from under the art, then leaves: nothing
        // sweeps at rest.
        #expect(await settle { !holdsABone(label) }, "a bone outlived its art")
    }

    /// ⚠️ THE FAILURE RULE (#1504, the owner 2026-10-21): no art to be had
    /// keeps a STILL skeleton in the square — never the system glyph, and
    /// nothing sweeping at rest (#580).
    @Test func aLabelFallsBackToTheGlyphWhenTheLoadFails() async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let (label, window) = hostedLabel("so 🔥 good", engine: gatedEngine(gate, answers: false))
        defer { window.isHidden = true }
        try #require(label.skeletonCount == 1)
        gate.open()
        try #require(await settle { label.pendingEmoteCount == 0 }, "the failed load never answered")
        #expect(label.skeletonCount == 1, "no skeleton after a failed load")
        let bone = try #require(label.skeletons.first?.boneView)
        #expect(!bone.isSweeping && !bone.showsBand, "a failed load's skeleton shimmers at rest")
        #expect(label.coveredMarkIndices == [0])
        #expect(EmoteLabelTests.colouredInk(of: label) == nil, "a glyph after a failed load")
        // Laid out again, it stays the still skeleton: not re-asked here.
        label.setNeedsLayout()
        label.layoutIfNeeded()
        #expect(label.skeletonCount == 1)
        #expect(label.pendingEmoteCount == 0, "the failure was asked again in place")
    }

    // MARK: - Pending, arrival, failure: tiles

    @Test func aTileShowsASkeletonThenTheArtInItsSquare() async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let engine = gatedEngine(gate)
        let (tile, window) = hostedTile()
        defer { window.isHidden = true }
        tile.configure(try emote("noto:1f525"), engine: engine, prefersAnimation: true)
        #expect(tile.showsSkeleton, "no skeleton for art on its way")
        #expect(!tile.showsGlyph)
        let square = tile.skeleton.frame
        #expect(square.width == 44 && square.height == 44, "the skeleton is not the tile's square: \(square)")

        gate.open()
        try #require(await settle { tile.isShowingArt }, "the art never came")
        #expect(!tile.showsSkeleton)
        #expect(!tile.showsGlyph, "a glyph showed after the art")
        #expect(tile.player.frame == square, "the art moved: \(tile.player.frame) vs \(square)")
        #expect(await settle { !holdsABone(tile) }, "a bone outlived its art")
    }

    @Test func aTileFallsBackToTheGlyphWhenTheLoadFails() async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let engine = gatedEngine(gate, answers: false)
        let (tile, window) = hostedTile()
        defer { window.isHidden = true }
        tile.configure(try emote("noto:1f525"), engine: engine, prefersAnimation: true)
        try #require(tile.showsSkeleton)
        gate.open()
        #expect(await settle { tile.showsGlyph }, "no glyph after a failed load")
        #expect(!tile.showsSkeleton)
        #expect(!tile.isShowingArt)
    }

    /// A tile reused before its art came gives its skeleton up at once.
    @Test func aReusedTileDropsItsSkeleton() throws {
        let gate = ArtGate()
        defer { gate.open() }
        let (tile, window) = hostedTile()
        defer { window.isHidden = true }
        tile.configure(try emote("noto:1f525"), engine: gatedEngine(gate), prefersAnimation: true)
        try #require(tile.showsSkeleton)
        tile.reset()
        #expect(!tile.showsSkeleton)
        #expect(!holdsABone(tile), "a reused tile kept a bone sweeping")
    }

    // MARK: - Pending, arrival, failure: the composer

    @Test func theComposerShowsASkeletonThenTheArt() async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let (field, window) = hostedField("cold 🔥", engine: gatedEngine(gate))
        defer { window.isHidden = true }
        try #require(await settle { field.emoteViews.count == 1 })
        let view = try #require(field.emoteViews.first)
        #expect(view.showsSkeleton, "no skeleton for art on its way: \(view.debugState)")
        #expect(view.skeleton.frame == view.bounds)
        let frame = view.frame

        gate.open()
        try #require(await settle { view.isShowingArt }, "the art never came: \(view.debugState)")
        #expect(!view.showsSkeleton)
        #expect(view.frame == frame, "the emote moved")
    }

    /// ⚠️ A still skeleton, never the glyph (#1504).
    @Test func theComposerFallsBackToTheGlyphWhenTheLoadFails() async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let (field, window) = hostedField("cold 🔥", engine: gatedEngine(gate, answers: false))
        defer { window.isHidden = true }
        try #require(await settle { field.emoteViews.count == 1 })
        let view = try #require(field.emoteViews.first)
        try #require(view.showsSkeleton)
        gate.open()
        #expect(await settle { view.skeleton.isFailed }, "no still skeleton after a failed load: \(view.debugState)")
        #expect(view.showsSkeleton)
        #expect(!view.isShowingArt)
    }

    // MARK: - Motion gates

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

    /// The witness: with no gate, the skeleton shimmers.
    @Test func withNoGateTheSkeletonShimmers() throws {
        let gate = ArtGate()
        defer { gate.open() }
        let engine = gatedEngine(gate)
        engine.skeletonConditions = { EmoteSkeleton.Conditions() }
        let (tile, window) = hostedTile()
        defer { window.isHidden = true }
        tile.configure(try emote("noto:1f525"), engine: engine, prefersAnimation: true)
        let bone = try #require(tile.skeleton.boneView)
        #expect(bone.isSweeping)
        #expect(bone.showsBand)
    }

    /// Each gate leaves a STILL square — no sweep, and no band parked
    /// mid-screen — on a tile, a label and the composer alike.
    @Test(arguments: Gate.allCases)
    func eachGateStillsTheShimmer(_ gate: Gate) async throws {
        let art = ArtGate()
        defer { art.open() }
        let engine = gatedEngine(art)
        engine.skeletonConditions = { gate.conditions }

        let (tile, w1) = hostedTile()
        defer { w1.isHidden = true }
        tile.configure(try emote("noto:1f525"), engine: engine, prefersAnimation: true)
        let tileBone = try #require(tile.skeleton.boneView)

        let (label, w2) = hostedLabel("so 🔥 good", engine: engine)
        defer { w2.isHidden = true }
        let labelBone = try #require(label.skeletons.first?.boneView)

        let (field, w3) = hostedField("cold 🔥", engine: engine)
        defer { w3.isHidden = true }
        try #require(await settle { field.emoteViews.first?.skeleton.boneView != nil })
        let fieldBone = try #require(field.emoteViews.first?.skeleton.boneView)

        for (surface, bone) in [("tile", tileBone), ("label", labelBone), ("composer", fieldBone)] {
            #expect(!bone.isSweeping, "\(surface): the skeleton sweeps under \(gate)")
            #expect(!bone.showsBand, "\(surface): a band parked mid-screen under \(gate)")
        }
    }

    /// The gates are decoration's own: what the app at large stills, the
    /// skeleton stills.
    @Test func theGatesAreDecorations() {
        #expect(EmoteSkeleton.Conditions.current.stillsShimmer == MotionPreference.stillsDecoration)
        #expect(!EmoteSkeleton.Conditions().stillsShimmer)
        #expect(Gate.allCases.allSatisfy { $0.conditions.stillsShimmer })
    }

    // MARK: - Seeded and cached art: never a skeleton

    /// Which art waits how long for its skeleton: a bake at once, a read
    /// (seed, disk, map icon) only after the grace.
    @Test func onlyArtThatMustBeBakedGetsASkeletonAtOnce() throws {
        let engine = EmoteEngine(diskCache: nil, seeds: .bundled, animationProvider: { _ in nil })
        let seeded = try emote("noto:1f602")
        let cold = try emote("noto:1f60e")
        #expect(engine.skeletonDelay(for: seeded, pixelSide: EmoteSeeds.side, motion: .loop) == engine.localArtGrace)
        #expect(engine.skeletonDelay(for: cold, pixelSide: EmoteSeeds.side, motion: .loop) == 0)
        // Seeds are one bucket, one motion.
        #expect(engine.skeletonDelay(for: seeded, pixelSide: 96, motion: .loop) == 0)
        #expect(engine.skeletonDelay(for: seeded, pixelSide: EmoteSeeds.side, motion: .still) == 0)
        if let icon = EmoteCatalog.shared.all.first(where: { if case .icon = $0.source { true } else { false } }) {
            #expect(engine.skeletonDelay(for: icon, pixelSide: 64, motion: .loop) == engine.localArtGrace)
        }
    }

    /// A seeded emote on a tile, cold engine, no disk: from the bundle to the
    /// art with no skeleton at any look.
    @Test func aSeededTileNeverShowsASkeleton() async throws {
        let engine = EmoteEngine(diskCache: nil, seeds: .bundled, animationProvider: { _ in nil })
        // Only the classification is under test, not the runner's speed.
        engine.localArtGrace = 600
        let (tile, window) = hostedTile()
        defer { window.isHidden = true }
        tile.configure(try emote("noto:1f602"), engine: engine, prefersAnimation: true)
        var skeletonSeen = tile.showsSkeleton
        let landed = await settle {
            skeletonSeen = skeletonSeen || tile.showsSkeleton
            return tile.isShowingArt
        }
        try #require(landed, "the seeded art never came")
        #expect(!skeletonSeen, "a seeded emote showed a skeleton")
        #expect(engine.stats.seedHits == 1)
        #expect(!holdsABone(tile))
    }

    /// The same on a label, at the seed's bucket.
    @Test func aSeededLabelNeverShowsASkeleton() async throws {
        let engine = EmoteEngine(diskCache: nil, seeds: .bundled, animationProvider: { _ in nil })
        engine.localArtGrace = 600
        let (label, window) = hostedLabel("so 😂 good", engine: engine)
        defer { window.isHidden = true }
        let square = try #require(label.emoteFrames.first)
        try #require(
            EmoteEngine.pixelSide(forPoints: square.width, scale: window.screen.scale) == EmoteSeeds.side,
            "the host's scale does not draw 17 pt at the seed's bucket"
        )
        var skeletonSeen = label.skeletonCount > 0
        let landed = await settle {
            label.layoutIfNeeded()
            skeletonSeen = skeletonSeen || label.skeletonCount > 0
            return label.showingEmoteCount == 1
        }
        try #require(landed, "the seeded art never came")
        #expect(!skeletonSeen, "a seeded emote showed a skeleton")
        #expect(!holdsABone(label))
    }

    /// Art in memory installs in the layout pass: no skeleton, on any surface.
    @Test func artInMemoryNeverShowsASkeleton() async throws {
        let engine = EmoteEngine(diskCache: nil, animationProvider: { _ in nil })
        let fire = try emote("noto:1f525")
        for side in EmoteEngine.pixelBuckets {
            engine.insert(EmoteLabelTests.syntheticArt(side: side), for: fire, pixelSide: side, motion: .loop)
        }
        let (label, w1) = hostedLabel("so 🔥 good", engine: engine)
        defer { w1.isHidden = true }
        #expect(label.showingEmoteCount == 1)
        #expect(label.skeletonCount == 0 && !holdsABone(label))

        let (tile, w2) = hostedTile()
        defer { w2.isHidden = true }
        tile.configure(fire, engine: engine, prefersAnimation: true)
        #expect(tile.isShowingArt)
        #expect(!tile.showsSkeleton && !holdsABone(tile))

        let (field, w3) = hostedField("so 🔥", engine: engine)
        defer { w3.isHidden = true }
        try #require(await settle { field.emoteViews.first?.isShowingArt == true })
        #expect(field.emoteViews.allSatisfy { !$0.showsSkeleton })
    }

    /// A sheet on disk (baked on an earlier launch): a read, so no skeleton
    /// while it lands — on a label and a tile.
    @Test func artOnDiskNeverShowsASkeleton() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UIAssetCaches.openDisk(root: root)
        let disk = EmoteDiskCache { store }
        let fire = try emote("noto:1f525")
        for side in EmoteEngine.pixelBuckets {
            guard case .sheet(let sheet) = EmoteLabelTests.syntheticArt(side: side) else { return }
            disk.store(sheet, gutter: 0, stem: EmoteDiskCache.fileStem(emoteID: fire.id, side: side, still: false))
        }
        let engine = EmoteEngine(diskCache: disk, animationProvider: { _ in nil })
        engine.localArtGrace = 600
        #expect(engine.isLocal(fire, pixelSide: 64, motion: .loop))

        let (label, w1) = hostedLabel("so 🔥 good", engine: engine)
        defer { w1.isHidden = true }
        let (tile, w2) = hostedTile()
        defer { w2.isHidden = true }
        tile.configure(fire, engine: engine, prefersAnimation: true)
        var skeletonSeen = false
        let landed = await settle {
            label.layoutIfNeeded()
            skeletonSeen = skeletonSeen || label.skeletonCount > 0 || tile.showsSkeleton
            return label.showingEmoteCount == 1 && tile.isShowingArt
        }
        try #require(landed, "the disk's art never came")
        #expect(!skeletonSeen, "a sheet on disk showed a skeleton")
        #expect(engine.stats.diskHits >= 1)
        #expect(engine.stats.bakesStarted == 0)
    }

    /// The disk is asked only once its index is open: never opened on the
    /// main actor to answer the question.
    @Test func anUnopenedDiskIsNeverOpenedToAsk() {
        let opened = Flag()
        let disk = EmoteDiskCache(store: { opened.value = true; return nil }, isOpen: { false })
        #expect(!disk.containsIfOpen(stem: "anything"))
        #expect(!opened.value, "the store was opened to answer")
    }

    /// #986's review, closed in #898: the app opens the UI assets disk off
    /// the main thread at start-up (`startCacheCoordinator()`), and the emotes'
    /// cache counts that open as its own. It used to know only of opens it
    /// made itself, so a sheet on disk read as "not local" until then.
    @Test func theAppsOffMainOpenCountsForTheEmotesDisk() async throws {
        let store = try #require(await Task.detached { UIAssetCaches.disk }.value)
        #expect(UIAssetCaches.isDiskOpen)
        let stem = "warm-up-\(UUID().uuidString)"
        try store.write(Data([1, 2, 3]), for: EmoteDiskCache.key(stem: stem))
        defer { store.removeValue(for: EmoteDiskCache.key(stem: stem)) }
        #expect(try #require(EmoteDiskCache.standard()).containsIfOpen(stem: stem))
    }

    /// The safety net: a read that is LATE — it fell through to a bake, or
    /// the device is starved — still gets its skeleton after the grace.
    @Test func aLateReadGetsItsSkeletonAfterTheGrace() async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let engine = EmoteEngine(diskCache: nil, seeds: .bundled, animationProvider: { _ in nil })
        engine.artProvider = { _, side, _ in
            await gate.wait()
            return EmoteLabelTests.syntheticArt(side: side)
        }
        engine.localArtGrace = 0.05
        let (tile, window) = hostedTile()
        defer { window.isHidden = true }
        tile.configure(try emote("noto:1f602"), engine: engine, prefersAnimation: true)
        #expect(!tile.showsSkeleton, "a seeded emote's skeleton came before its grace")
        #expect(!tile.showsGlyph, "a glyph while a seed is read")
        #expect(await settle { tile.showsSkeleton }, "a late read never got its skeleton")
        gate.open()
        #expect(await settle { tile.isShowingArt })
        #expect(!tile.showsSkeleton)
    }

    /// #936 / #922: a hero landing un-hides the label and asks again; art
    /// still in memory plays in that pass, with no skeleton frame — and art
    /// gone from memory but on disk leaves the square empty for its read,
    /// with no skeleton either.
    @Test func aLandingNeverFlashesASkeletonForCachedArt() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UIAssetCaches.openDisk(root: root)
        let disk = EmoteDiskCache { store }
        let fire = try emote("noto:1f525")
        let engine = EmoteEngine(diskCache: disk, animationProvider: { _ in nil })
        engine.localArtGrace = 600
        for side in EmoteEngine.pixelBuckets {
            let art = EmoteLabelTests.syntheticArt(side: side)
            engine.insert(art, for: fire, pixelSide: side, motion: .loop)
            guard case .sheet(let sheet) = art else { return }
            disk.store(sheet, gutter: 0, stem: EmoteDiskCache.fileStem(emoteID: fire.id, side: side, still: false))
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false
        defer { window.isHidden = true }
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        let label = EmoteLabel()
        label.engine = engine
        label.font = font
        label.setEmoteText("🔥🔥")
        container.addSubview(label)
        label.frame = CGRect(x: 10, y: 10, width: 300, height: 30)
        label.layoutIfNeeded()
        try #require(label.showingEmoteCount == 2)

        // The flight hides the cell; the landing shows it again and asks.
        container.isHidden = true
        EmoteVisibilityMonitor.shared.tick()
        label.layoutIfNeeded()
        try #require(label.placedEmoteCount == 0)
        container.isHidden = false
        EmoteLabel.recheckVisibility()
        label.layoutIfNeeded()
        #expect(label.showingEmoteCount == 2)
        #expect(label.skeletonCount == 0, "a skeleton frame at the landing, for art in memory")

        // Memory evicted, disk kept: the read lands, no skeleton meanwhile.
        container.isHidden = true
        EmoteVisibilityMonitor.shared.tick()
        label.layoutIfNeeded()
        engine.purgeMemory()
        container.isHidden = false
        EmoteLabel.recheckVisibility()
        label.layoutIfNeeded()
        #expect(label.skeletonCount == 0, "a skeleton frame at the landing, for art on disk")
        #expect(label.coveredMarkIndices == [0, 1], "a glyph frame at the landing")
    }

    // MARK: - Budget

    /// Past the label budget, art that lands takes its poster frame — never
    /// the glyph between the skeleton and the art.
    @Test func overTheBudgetTheSkeletonGivesWayToThePosterNotTheGlyph() async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let engine = gatedEngine(gate)
        engine.maxAnimatedEmotes = 1
        let (label, window) = hostedLabel("🔥 🔥", engine: engine)
        defer { window.isHidden = true }
        try #require(label.skeletonCount == 2)
        gate.open()
        let landed = await settle {
            label.layoutIfNeeded()
            return label.pendingEmoteCount == 0
        }
        try #require(landed)
        #expect(label.showingEmoteCount == 1)
        #expect(label.posterEmoteCount == 1, "past the budget, not the art's poster")
        #expect(label.skeletonCount == 0)
        #expect(label.coveredMarkIndices == [0, 1], "a glyph behind an animated emote")
    }
}

/// Holds art back until the test opens it.
@MainActor
final class ArtGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiters
        waiters.removeAll()
        resumed.forEach { $0.resume() }
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}
