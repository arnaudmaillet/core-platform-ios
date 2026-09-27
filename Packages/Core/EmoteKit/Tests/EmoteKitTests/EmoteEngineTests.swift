import Foundation
import Lottie
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The bake plan: frame counts, grids and the two caps.
struct EmoteBakePlanTests {
    @Test func aTwoSecondLoopIs60FramesAt30fps() {
        let plan = EmoteBakePlan.make(seconds: 2, side: 64)
        #expect(plan.frameCount == 60)
        #expect(plan.columns == 8)
        #expect(plan.rows == 8)
        #expect(plan.pitch == 68)
        #expect(plan.pixelWidth == 8 * 68)
        #expect(abs(plan.frameDuration * Double(plan.frameCount) - 2) < 1e-9)
    }

    /// Noto's longest loop keeps its whole duration at a lower rate.
    @Test func aLongLoopIsCappedByCountAndKeepsItsDuration() {
        let plan = EmoteBakePlan.make(seconds: 5.75, side: 64)
        #expect(plan.frameCount == EmoteBakePlan.maxFrames)
        #expect(abs(plan.frameDuration * Double(plan.frameCount) - 5.75) < 1e-9)
    }

    /// The big bucket is capped by BYTES before it is capped by count.
    @Test func aBigSheetIsCappedByBytes() {
        let plan = EmoteBakePlan.make(seconds: 2, side: 128)
        #expect(plan.byteCost <= EmoteBakePlan.maxBytes)
        #expect(plan.frameCount < 60)
        // …and only just: one more frame would not fit.
        let bigger = EmoteBakePlan.gridBytes(
            frames: plan.frameCount + 1, columns: EmoteBakePlan.columnCount(for: plan.frameCount + 1), pitch: 132
        )
        #expect(bigger > EmoteBakePlan.maxBytes)
    }

    @Test func aStillIsOneFrame() {
        let plan = EmoteBakePlan.make(seconds: 2, side: 64, still: true)
        #expect(plan.frameCount == 1)
        #expect(plan.columns == 1)
        #expect(plan.byteCost == 68 * 68 * 4)
    }

    /// Frames are laid out row-major from the TOP, inside their gutter — the
    /// order `AnimatedIconSheet.frameRects` reads them in.
    @Test func framesAreRowMajorFromTheTop() {
        let plan = EmoteBakePlan.make(seconds: 2, side: 64)
        #expect(plan.origin(ofFrame: 0) == (2, 2))
        #expect(plan.origin(ofFrame: 1) == (70, 2))
        #expect(plan.origin(ofFrame: 8) == (2, 70))
    }

    @Test func textSizesRoundUpToABucket() {
        // Body text's emoji at 3x, a 15 pt comment's, a caption at 2x.
        #expect(EmoteEngine.pixelSide(forPoints: 20.3, scale: 3) == 64)
        #expect(EmoteEngine.pixelSide(forPoints: 18, scale: 3) == 64)
        #expect(EmoteEngine.pixelSide(forPoints: 15, scale: 3) == 48)
        #expect(EmoteEngine.pixelSide(forPoints: 20, scale: 2) == 48)
        #expect(EmoteEngine.pixelSide(forPoints: 60, scale: 3) == 128)
    }
}

/// Baking real emotes, caching, dedup and cancellation.
@MainActor
@Suite(.serialized)
struct EmoteEngineTests {
    private let catalog = EmoteCatalog.shared

    private func emote(_ id: String) throws -> Emote {
        try #require(catalog.emote(id: id))
    }

    private func scratchDisk() -> EmoteDiskCache {
        EmoteDiskCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("emote-tests-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func aNotoEmojiBakesIntoAMovingSheet() async throws {
        let engine = EmoteEngine(diskCache: nil)
        let fire = try emote("noto:1f525")
        let art = try #require(await engine.art(for: fire, pixelSide: 64))
        guard case .sheet(let sheet) = art else {
            Issue.record("expected a sheet")
            return
        }
        let animation = try #require(await EmoteEngine.bundledAnimation(for: fire))
        let plan = EmoteBakePlan.make(seconds: animation.duration, side: 64)
        #expect(sheet.frameCount == plan.frameCount)
        #expect(sheet.frameCount > 20)
        let image = try #require(sheet.sheet.cgImage)
        #expect(image.width == plan.pixelWidth)
        #expect(image.height == plan.pixelHeight)
        #expect(art.byteCost == plan.byteCost)

        // Ink in the first frame, and the loop actually moves.
        let first = TestBitmap.cell(image, plan: plan, frame: 0)
        let middle = TestBitmap.cell(image, plan: plan, frame: plan.frameCount / 2)
        #expect(first.inked > 64 * 64 / 8, "first frame has \(first.inked) inked pixels")
        #expect(first.pixels != middle.pixels)
        // The gutter stays empty, or sampling would bleed across frames.
        #expect(TestBitmap.gutterInk(image, plan: plan) == 0)
        #expect(engine.stats.bakesStarted == 1)
        #expect(engine.stats.bakesFinished == 1)
    }

    @Test func aStickerBakesToo() async throws {
        let engine = EmoteEngine(diskCache: nil)
        let lmao = try emote("lmao")
        let art = try #require(await engine.art(for: lmao, pixelSide: 48))
        #expect(art.frameCount > 1)
    }

    /// Two labels asking for one sheet while it bakes wait on ONE bake, and
    /// the next ask is answered from memory before `requestArt` returns.
    @Test func concurrentRequestsShareOneBake() async throws {
        let engine = EmoteEngine(diskCache: nil)
        let joy = try emote("noto:1f602")
        async let first = engine.art(for: joy, pixelSide: 48)
        async let second = engine.art(for: joy, pixelSide: 48)
        let pair = await (first, second)
        let art = try #require(pair.0)
        #expect(pair.1 == art)
        #expect(engine.stats.bakesStarted == 1)

        var answered: AnimatedIconArt?
        engine.requestArt(for: joy, pixelSide: 48, motion: .loop) { answered = $0 }
        #expect(answered == art)
        #expect(engine.stats.bakesStarted == 1)

        // Another bucket is another sheet.
        _ = await engine.art(for: joy, pixelSide: 64)
        #expect(engine.stats.bakesStarted == 2)
    }

    /// A request cancelled before its bake finishes is never answered, and a
    /// bake nobody waits for stops.
    @Test func aCancelledRequestStopsItsBake() async throws {
        let gate = Gate()
        let engine = EmoteEngine(diskCache: nil) { emote in
            await gate.wait()
            return await EmoteEngine.bundledAnimation(for: emote)
        }
        let fire = try emote("noto:1f525")
        var answers = 0
        let request = engine.requestArt(for: fire, pixelSide: 48, motion: .loop) { _ in answers += 1 }
        #expect(engine.isBaking(fire, pixelSide: 48, motion: .loop))
        request.cancel()
        #expect(!engine.isBaking(fire, pixelSide: 48, motion: .loop))
        #expect(engine.stats.bakesCancelled == 1)
        gate.open()
        // Let the cancelled task run to its end.
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(answers == 0)
        #expect(engine.stats.bakesStarted == 0, "a cancelled request still baked")
        #expect(engine.cachedArt(for: fire, pixelSide: 48, motion: .loop) == nil)
    }

    /// Cancelling ONE of two waiters leaves the other's bake running.
    @Test func cancellingOneWaiterKeepsTheOther() async throws {
        let engine = EmoteEngine(diskCache: nil)
        let fire = try emote("noto:1f525")
        let dropped = engine.requestArt(for: fire, pixelSide: 48, motion: .loop) { _ in
            Issue.record("a cancelled request was answered")
        }
        let kept = await withCheckedContinuation { (continuation: CheckedContinuation<AnimatedIconArt?, Never>) in
            engine.requestArt(for: fire, pixelSide: 48, motion: .loop) { continuation.resume(returning: $0) }
            dropped.cancel()
        }
        #expect(kept != nil)
        #expect(engine.stats.bakesCancelled == 0)
    }

    /// A sheet is baked once per install and size: a new engine (a new
    /// launch) reads it back from disk.
    @Test func sheetsSurviveOnDisk() async throws {
        let disk = scratchDisk()
        defer { disk.removeAll() }
        let heart = try emote("noto:2764_fe0f")
        let first = EmoteEngine(diskCache: disk)
        let baked = try #require(await first.art(for: heart, pixelSide: 48))
        // The write is fire-and-forget; wait for both files.
        let stem = EmoteDiskCache.fileStem(emoteID: heart.id, side: 48, still: false)
        for _ in 0..<200 where !FileManager.default.fileExists(
            atPath: disk.directory.appendingPathComponent(stem + ".json").path
        ) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = EmoteEngine(diskCache: disk)
        let loaded = try #require(await second.art(for: heart, pixelSide: 48))
        #expect(second.stats.diskHits == 1)
        #expect(second.stats.bakesStarted == 0)
        #expect(loaded.frameCount == baked.frameCount)
        #expect(loaded.frameDuration == baked.frameDuration)
    }

    @Test func aStillIsOneFrameAndCachedApart() async throws {
        let engine = EmoteEngine(diskCache: nil)
        let fire = try emote("noto:1f525")
        let still = try #require(await engine.art(for: fire, pixelSide: 48, motion: .still))
        #expect(still.frameCount == 1)
        #expect(engine.cachedArt(for: fire, pixelSide: 48, motion: .loop) == nil)
    }

    /// Without an icon catalogue a map-icon emote has no art — its stand-in
    /// glyph stays, and nothing throws.
    @Test func anIconEmoteWithoutACatalogueHasNoArt() async throws {
        let engine = EmoteEngine(diskCache: nil)
        let lol = try emote("lol")
        #expect(await engine.art(for: lol, pixelSide: 48) == nil)
    }

    /// THE MAIN-THREAD CONTRACT: a bake draws no frame on the main thread.
    /// Once its tree is built and the main thread has run the tree's birth
    /// redraw (`EmoteBakeSession.waitForBirthRedraw`), the main thread is
    /// BLOCKED here while the whole sheet is drawn; were a single frame drawn
    /// on it, this would time out.
    @Test func aBakeDrawsNoFrameOnTheMainThread() async throws {
        let cold = try emote("noto:1f976")
        let animation = try #require(await EmoteEngine.bundledAnimation(for: cold))
        let plan = EmoteBakePlan.make(seconds: animation.duration, side: 48)
        let done = DispatchSemaphore(value: 0)
        let result = BakeBox()
        Task.detached {
            result.set(await EmoteBakeQueue.shared.bake(animation, plan: plan))
            done.signal()
        }
        for _ in 0..<2000 where EmoteBakeQueue.shared.drawingJobs == 0 && result.value == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(Self.block(on: done, seconds: 60), "the bake did not finish while the main thread was blocked")
        let baked = try #require(result.value)
        #expect(baked.image.width == plan.pixelWidth)
        #expect(baked.image.height == plan.pixelHeight)
    }

    /// Blocks the calling (main) thread — deliberately synchronous.
    private nonisolated static func block(on semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }

    /// The sheet a bake draws off the main thread looks like the one the old
    /// main-thread drawer (a `LottieAnimationView`) drew, frame for frame.
    /// Not byte for byte: backing stores are drawn at 4× the cell, not at
    /// the composition's size (`EmoteFrameDrawer.supersampling`) — measured
    /// ≤ 16/255 apart, 42 on 🔥's sparks. A wrong frame (a matte that cut
    /// nothing) is thousands of channels ~100 apart.
    @Test func offMainFramesMatchTheMainThreadDrawer() async throws {
        for id in ["noto:1f602", "noto:1f976", "noto:1f525", "noto:1f914"] {
            let animation = try #require(await EmoteEngine.bundledAnimation(for: try emote(id)))
            let plan = EmoteBakePlan.make(seconds: animation.duration, side: 64)
            let reference = try #require(ReferenceMainThreadDrawer.sheet(animation, plan: plan))
            let baked = try #require(await EmoteBakeQueue.shared.bake(animation, plan: plan))
            let far = TestBitmap.channelsApart(reference, baked.image, by: 48)
            #expect(far == 0, "\(id): \(far) channels more than 48/255 from the main-thread drawer")
        }
    }

    /// THE NO-RACE CONTRACT: with the main thread drawing Lottie in bursts
    /// meanwhile — the reproducer that turned one frame of 😂 orange in
    /// nearly every bake while the tree's birth redraw ran on the main thread
    /// mid-bake — a bake draws exactly what it draws alone.
    @Test func aBakeUnderMainThreadLottieLoadMatchesOneAlone() async throws {
        let stress = try #require(await EmoteEngine.bundledAnimation(for: try emote("noto:1f62d")))
        let burst = EmoteBakePlan.make(seconds: 0.3, side: 48)
        for id in ["noto:1f602", "noto:1f979", "noto:1f525"] {
            let animation = try #require(await EmoteEngine.bundledAnimation(for: try emote(id)))
            let plan = EmoteBakePlan.make(seconds: animation.duration, side: 48)
            let alone = try #require(await EmoteBakeQueue.shared.bake(animation, plan: plan))
            for _ in 0..<3 {
                let bake = Task.detached(priority: .utility) { await EmoteBakeQueue.shared.bake(animation, plan: plan) }
                while EmoteBakeQueue.shared.pendingJobs > 0 {
                    _ = ReferenceMainThreadDrawer.sheet(stress, plan: burst)
                    try await Task.sleep(for: .milliseconds(5))
                }
                let loaded = try #require(await bake.value)
                let far = TestBitmap.channelsApart(alone.image, loaded.image, by: 8)
                #expect(far == 0, "\(id): \(far) channels differ from the same bake alone")
            }
        }
    }

    /// What the drawer relies on inside Lottie, checked so a Lottie update
    /// that moves it fails HERE rather than silently: inverted mattes are
    /// found (through `inputMatte`), and every layer draws at the cell's
    /// supersampled scale, not the canvas's.
    @Test func theDrawerFindsMattesAndScalesEveryStore() async throws {
        let joy = try #require(await EmoteEngine.bundledAnimation(for: try emote("noto:1f602")))
        let drawer = try #require(EmoteFrameDrawer(animation: joy, side: 64))
        #expect(drawer.invertedMatteCount == 1)
        #expect(drawer.selfDrawingCount >= 2, "the inverted matte and its gradient at least")
        #expect(drawer.layerCount > 20)
        let expected = EmoteFrameDrawer.supersampling * 64 / max(joy.bounds.width, joy.bounds.height)
        #expect(drawer.backingStoreScales == [expected])

        let fire = try #require(await EmoteEngine.bundledAnimation(for: try emote("noto:1f525")))
        #expect(try #require(EmoteFrameDrawer(animation: fire, side: 64)).invertedMatteCount == 0)
    }

    /// The numbers for the record: bake time and memory for a spread of real
    /// emoji at the text bucket. Asserts only what must hold everywhere.
    @Test func bakeCostsForTheRecord() async throws {
        let engine = EmoteEngine(diskCache: nil)
        let ids = ["noto:1f602", "noto:2764_fe0f", "noto:1f923", "noto:1f44d", "noto:1f62d",
                   "noto:1f525", "noto:1f60d", "noto:1f389", "noto:1f41d", "noto:1f483", "lmao"]
        var lines: [String] = []
        for id in ids {
            let emote = try emote(id)
            let started = ContinuousClock.now
            let art = try #require(await engine.art(for: emote, pixelSide: 64))
            let wall = (ContinuousClock.now - started).milliseconds
            lines.append(String(
                format: "%@ %@ frames=%d bytes=%.2fMB offMainDrawingMS=%.1f bakeWallMS=%.1f totalMS=%.1f",
                emote.glyph, id, art.frameCount, Double(art.byteCost) / 1_048_576,
                engine.stats.lastBakeDrawingMS, engine.stats.lastBakeWallMS, wall
            ))
            #expect(art.byteCost <= EmoteBakePlan.maxBytes)
        }
        print("[emote-costs]\n" + lines.joined(separator: "\n"))
    }
}

/// Carries a bake's result out of a detached task.
final class BakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: EmoteBakeResult?
    var value: EmoteBakeResult? { lock.withLock { stored } }
    func set(_ result: EmoteBakeResult?) { lock.withLock { stored = result } }
}

/// The drawer bakes used before they moved off the main thread: a
/// `.mainThread` `LottieAnimationView`, driven by `currentTime` and captured
/// with `render(in:)`. Kept here as the reference the off-main path must match.
@MainActor
enum ReferenceMainThreadDrawer {
    static func sheet(_ animation: LottieAnimation, plan: EmoteBakePlan) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: plan.pixelWidth, height: plan.pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(plan.pixelHeight))
        context.scaleBy(x: 1, y: -1)
        let view = LottieAnimationView(animation: animation, configuration: LottieConfiguration(renderingEngine: .mainThread))
        view.contentMode = .scaleAspectFit
        view.frame = CGRect(x: 0, y: 0, width: plan.side, height: plan.side)
        view.layoutIfNeeded()
        for index in 0..<plan.frameCount {
            let origin = plan.origin(ofFrame: index)
            context.saveGState()
            context.translateBy(x: CGFloat(origin.x), y: CGFloat(origin.y))
            view.currentTime = plan.time(ofFrame: index)
            view.layer.displayIfNeeded()
            view.layer.sublayers?.forEach { $0.displayIfNeeded() }
            view.layer.render(in: context)
            context.restoreGState()
        }
        return context.makeImage()
    }
}

/// A one-shot latch a test opens.
@MainActor
final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Pixel reading for sheets.
enum TestBitmap {
    struct Cell {
        let pixels: [UInt8]
        let inked: Int
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// Frame `frame`'s art (gutter excluded), top-down.
    static func cell(_ image: CGImage, plan: EmoteBakePlan, frame: Int) -> Cell {
        let all = rgba(image)
        let origin = plan.origin(ofFrame: frame)
        var pixels: [UInt8] = []
        var inked = 0
        for y in origin.y..<(origin.y + plan.side) {
            for x in origin.x..<(origin.x + plan.side) {
                let offset = (y * image.width + x) * 4
                pixels.append(contentsOf: all[offset..<(offset + 4)])
                if all[offset + 3] > 16 { inked += 1 }
            }
        }
        return Cell(pixels: pixels, inked: inked)
    }

    /// Channels (of all pixels) more than `threshold` apart in two equally
    /// sized images.
    static func channelsApart(_ a: CGImage, _ b: CGImage, by threshold: Int) -> Int {
        let x = rgba(a), y = rgba(b)
        guard x.count == y.count else { return Int.max }
        return zip(x, y).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > threshold ? 1 : 0) }
    }

    /// Inked pixels in the gutters between cells.
    static func gutterInk(_ image: CGImage, plan: EmoteBakePlan) -> Int {
        let all = rgba(image)
        var inked = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let inCellX = x % plan.pitch
                let inCellY = y % plan.pitch
                let inArt = inCellX >= plan.gutter && inCellX < plan.gutter + plan.side
                    && inCellY >= plan.gutter && inCellY < plan.gutter + plan.side
                if !inArt && all[(y * image.width + x) * 4 + 3] > 8 { inked += 1 }
            }
        }
        return inked
    }
}
