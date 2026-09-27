import Foundation
import Lottie
import MediaCore
import StickerKit
import UIKit

/// Turns an emote into playable art — once — and shares it.
///
/// ## Where art comes from
///
/// - **Lottie emotes** (Noto emoji, StickerKit stickers) are BAKED: drawn once
///   into a small sprite sheet at a text-size bucket (`pixelBuckets`), OFF the
///   main thread (`EmoteBakeQueue`), then kept in memory and on disk.
/// - **Map icons** are already baked by `Tools/IconBaker`; they come straight
///   from the app's `AnimatedIconCatalog`.
///
/// Either way the result is an `AnimatedIconArt`, played by the map's own
/// `AnimatedIconView`: a `CAKeyframeAnimation` on `contentsRect`, run by the
/// render server. Once an emote is on screen the app's main thread never
/// wakes for it again.
///
/// ## Requests
///
/// Asking twice for one sheet while it bakes waits on ONE bake. A request is
/// cancellable, and a bake nobody is waiting for any more stops at its next
/// frame — a caption scrolled past before its emoji baked costs one frame of
/// background work.
@MainActor
public final class EmoteEngine {
    public static let shared = EmoteEngine()

    /// Whether art is a whole loop or its first frame alone.
    public enum Motion: Sendable, Hashable {
        case loop
        /// For Reduce Motion: one frame, baked alone.
        case still
    }

    /// Sides a sheet is baked at, in pixels. A text size is rounded UP to the
    /// next one, so a handful of sheets serves every font in the app: body text
    /// at 3x (about 61 px) and a 15 pt comment (about 54 px) both take 64.
    public nonisolated static let pixelBuckets = [48, 64, 96, 128]

    /// The map's baked icon catalogue, for the house emotes drawn from it. The
    /// app sets it at launch; while it is nil those emotes stay on their
    /// stand-in emoji.
    public var iconCatalog: AnimatedIconCatalog?

    public let catalog: EmoteCatalog

    /// How many emotes may ANIMATE at once, across every label on screen. The
    /// rest show their static glyph until a slot frees. A render-server
    /// animation costs little, but a comment list full of 🔥 should not become
    /// a hundred of them.
    public var maxAnimatedEmotes = 48

    /// How long a bake waits before starting, so a request cancelled within it
    /// (a page swiped past) never loads or draws anything.
    var bakeDelay = Duration.milliseconds(150)

    /// What the engine has done, for tests and the debug log.
    public struct Stats: Equatable, Sendable {
        public internal(set) var bakesStarted = 0
        public internal(set) var bakesFinished = 0
        public internal(set) var bakesCancelled = 0
        public internal(set) var diskHits = 0
        public internal(set) var memoryHits = 0
        /// Milliseconds the most recent bake spent drawing — on the bake
        /// queue, never on the main thread.
        public internal(set) var lastBakeDrawingMS: Double = 0
        public internal(set) var lastBakeWallMS: Double = 0
        public internal(set) var lastBakeBytes = 0
    }
    public private(set) var stats = Stats()

    /// Where Lottie emotes come from. Replaceable so a test can bake without
    /// the bundle.
    typealias AnimationProvider = @MainActor (Emote) async -> LottieAnimation?
    let animationProvider: AnimationProvider

    private let cache = NSCache<NSString, ArtBox>()
    private let diskCache: EmoteDiskCache?
    private var pending: [String: Pending] = [:]
    private var nextToken = 0
    private(set) var animatedCount = 0
    private let waitingForPlayback = NSHashTable<AnyObject>.weakObjects()

    /// - Parameter memoryBudgetMB: a BYTE budget for resident sheets — a 64 px
    ///   sheet is about a megabyte, so a count limit would never bind.
    init(
        catalog: EmoteCatalog = .shared,
        diskCache: EmoteDiskCache? = .standard(),
        memoryBudgetMB: Int = 32,
        animationProvider: AnimationProvider? = nil
    ) {
        self.catalog = catalog
        self.diskCache = diskCache
        self.animationProvider = animationProvider ?? { emote in await EmoteEngine.bundledAnimation(for: emote) }
        cache.totalCostLimit = memoryBudgetMB * 1024 * 1024
    }

    // MARK: - Sizes

    /// The bucket for an emote drawn `points` wide on a `scale` screen.
    public nonisolated static func pixelSide(forPoints points: CGFloat, scale: CGFloat) -> Int {
        let needed = Int((points * max(scale, 1)).rounded(.up))
        return pixelBuckets.first { $0 >= needed } ?? pixelBuckets[pixelBuckets.count - 1]
    }

    // MARK: - Art

    /// The art already resident for this emote, size and motion — what a label
    /// installs in the same layout pass, with no flash.
    public func cachedArt(for emote: Emote, pixelSide: Int, motion: Motion) -> AnimatedIconArt? {
        let key = Self.key(emote, pixelSide: pixelSide, motion: motion)
        if let box = cache.object(forKey: key as NSString) {
            stats.memoryHits += 1
            return box.art
        }
        return nil
    }

    /// Resolves the art, baking it if needed, and calls `completion` on the
    /// main actor with it — or with nil when there is none (a missing file, no
    /// icon catalogue). Never called after the request is cancelled.
    ///
    /// A cached answer is delivered BEFORE this returns.
    @discardableResult
    public func requestArt(
        for emote: Emote,
        pixelSide: Int,
        motion: Motion,
        completion: @escaping @MainActor (AnimatedIconArt?) -> Void
    ) -> EmoteRequest {
        if let art = cachedArt(for: emote, pixelSide: pixelSide, motion: motion) {
            completion(art)
            return EmoteRequest(engine: nil, key: "", token: 0)
        }
        let key = Self.key(emote, pixelSide: pixelSide, motion: motion)
        nextToken += 1
        let token = nextToken
        if let running = pending[key] {
            running.waiters[token] = completion
            return EmoteRequest(engine: self, key: key, token: token)
        }
        let job = Pending()
        job.waiters[token] = completion
        pending[key] = job
        job.task = Task { [weak self] in
            let art = await self?.produce(emote, pixelSide: pixelSide, motion: motion)
            self?.finish(key: key, job: job, art: art)
        }
        return EmoteRequest(engine: self, key: key, token: token)
    }

    /// Resolves the art with `async`/`await`. Cancelling the calling task
    /// cancels the request, and answers nil.
    public func art(for emote: Emote, pixelSide: Int, motion: Motion = .loop) async -> AnimatedIconArt? {
        let holder = AwaitedRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AnimatedIconArt?, Never>) in
                holder.continuation = continuation
                holder.request = requestArt(for: emote, pixelSide: pixelSide, motion: motion) { art in
                    holder.resume(art)
                }
            }
        } onCancel: {
            Task { @MainActor in holder.cancel() }
        }
    }

    /// Whether a bake for this emote is running.
    func isBaking(_ emote: Emote, pixelSide: Int, motion: Motion) -> Bool {
        pending[Self.key(emote, pixelSide: pixelSide, motion: motion)] != nil
    }

    /// Puts `art` in the memory cache as if it had been baked — a test seam.
    func insert(_ art: AnimatedIconArt, for emote: Emote, pixelSide: Int, motion: Motion) {
        cache.setObject(ArtBox(art), forKey: Self.key(emote, pixelSide: pixelSide, motion: motion) as NSString,
                        cost: art.byteCost)
    }

    /// Drops every resident sheet (the disk copies stay).
    public func purgeMemory() {
        cache.removeAllObjects()
    }

    fileprivate func cancel(key: String, token: Int) -> Bool {
        guard let job = pending[key], job.waiters.removeValue(forKey: token) != nil else { return false }
        if job.waiters.isEmpty {
            job.task?.cancel()
            pending[key] = nil
            stats.bakesCancelled += 1
        }
        return true
    }

    private func finish(key: String, job: Pending, art: AnimatedIconArt?) {
        if let art {
            cache.setObject(ArtBox(art), forKey: key as NSString, cost: art.byteCost)
        }
        // A job cancelled while it drew may still finish; its art is kept, but
        // a NEWER job for the same key must not be answered or removed by it.
        guard pending[key] === job else { return }
        pending[key] = nil
        let waiters = job.waiters.sorted { $0.key < $1.key }.map(\.value)
        job.waiters.removeAll()
        waiters.forEach { $0(art) }
    }

    private func produce(_ emote: Emote, pixelSide: Int, motion: Motion) async -> AnimatedIconArt? {
        if case .icon(let id) = emote.source {
            guard let art = try? await iconCatalog?.art(for: id) else { return nil }
            // The map's sheets are drawn on white paper (`EmoteIconMatte`).
            return await Task.detached(priority: .userInitiated) { EmoteIconMatte.matted(art) }.value
        }
        let stem = EmoteDiskCache.fileStem(emoteID: emote.id, side: pixelSide, still: motion == .still)
        if let diskCache {
            let hit = await Task.detached(priority: .userInitiated) { diskCache.load(stem: stem) }.value
            if let hit {
                stats.diskHits += 1
                return hit
            }
        }
        // A beat before any work: a caption flicked past in the meantime
        // cancels its request and costs nothing at all.
        if bakeDelay > .zero { try? await Task.sleep(for: bakeDelay) }
        guard !Task.isCancelled, let animation = await animationProvider(emote), !Task.isCancelled else { return nil }
        let plan = EmoteBakePlan.make(seconds: animation.duration, side: pixelSide, still: motion == .still)
        stats.bakesStarted += 1
        let clock = ContinuousClock()
        let started = clock.now
        guard let baked = await EmoteBakeQueue.shared.bake(animation, plan: plan), !Task.isCancelled else { return nil }
        let sheet = AnimatedIconSheet(
            sheet: UIImage(cgImage: baked.image), frameCount: plan.frameCount, columns: plan.columns,
            frameDuration: plan.frameDuration, gutterPX: plan.gutter
        )
        let art = AnimatedIconArt.sheet(sheet)
        stats.bakesFinished += 1
        stats.lastBakeDrawingMS = baked.drawingTime.milliseconds
        stats.lastBakeWallMS = (clock.now - started).milliseconds
        stats.lastBakeBytes = plan.byteCost
        #if DEBUG
        print(String(
            format: "[emote] baked %@@%d %df %.2fMB off-main drawing=%.1fms (%.1fms/frame) wall=%.1fms",
            emote.id, pixelSide, plan.frameCount, Double(plan.byteCost) / 1_048_576,
            stats.lastBakeDrawingMS, stats.lastBakeDrawingMS / Double(plan.frameCount), stats.lastBakeWallMS
        ))
        #endif
        if let diskCache {
            let gutter = plan.gutter
            Task.detached(priority: .utility) { diskCache.store(sheet, gutter: gutter, stem: stem) }
        }
        return art
    }

    private static func key(_ emote: Emote, pixelSide: Int, motion: Motion) -> String {
        // An icon is baked once by the tool, at its own size.
        if case .icon = emote.source { return "\(emote.id)@icon" }
        return "\(emote.id)@\(pixelSide)\(motion == .still ? "-still" : "")"
    }

    // MARK: - Playback budget

    /// Takes one of the `maxAnimatedEmotes` slots. False when they are all
    /// taken; `waiter` is then told (`emotePlaybackSlotFreed`) when one frees.
    func acquirePlaybackSlot(waiter: EmotePlaybackWaiting) -> Bool {
        guard animatedCount < maxAnimatedEmotes else {
            waitingForPlayback.add(waiter)
            return false
        }
        animatedCount += 1
        return true
    }

    func releasePlaybackSlot() {
        animatedCount = max(0, animatedCount - 1)
        let waiters = waitingForPlayback.allObjects.compactMap { $0 as? EmotePlaybackWaiting }
        waitingForPlayback.removeAllObjects()
        waiters.forEach { $0.emotePlaybackSlotFreed() }
    }

    // MARK: - Bundled sources

    /// The Lottie for a Noto emoji or a sticker, decoded off the main actor.
    static func bundledAnimation(for emote: Emote) async -> LottieAnimation? {
        switch emote.source {
        case .noto(let codepoint):
            return await Task.detached(priority: .userInitiated) {
                NotoLottieSource.animation(codepoint: codepoint, bundle: .module)
            }.value
        case .sticker(let id):
            guard let sticker = StickerCatalog.sticker(id: id) else { return nil }
            return await StickerCatalog.file(for: sticker)?.animations.first?.animation
        case .icon:
            return nil
        }
    }
}

/// Something that wants to know when an animation slot frees.
@MainActor
protocol EmotePlaybackWaiting: AnyObject {
    func emotePlaybackSlotFreed()
}

/// A pending `EmoteEngine.requestArt`. Cancelling it stops its completion, and
/// stops the bake once nobody else is waiting for it.
@MainActor
public final class EmoteRequest {
    private weak var engine: EmoteEngine?
    private let key: String
    private let token: Int
    public private(set) var isCancelled = false

    init(engine: EmoteEngine?, key: String, token: Int) {
        self.engine = engine
        self.key = key
        self.token = token
    }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        _ = engine?.cancel(key: key, token: token)
    }
}

/// Bridges one callback request to `async`: resumes exactly once, with the
/// art or with nil on cancellation.
@MainActor
private final class AwaitedRequest {
    var continuation: CheckedContinuation<AnimatedIconArt?, Never>?
    var request: EmoteRequest?

    func resume(_ art: AnimatedIconArt?) {
        continuation?.resume(returning: art)
        continuation = nil
    }

    func cancel() {
        request?.cancel()
        resume(nil)
    }
}

private final class ArtBox {
    let art: AnimatedIconArt
    init(_ art: AnimatedIconArt) { self.art = art }
}

@MainActor
private final class Pending {
    var task: Task<Void, Never>?
    var waiters: [Int: @MainActor (AnimatedIconArt?) -> Void] = [:]
}

/// Reads a bundled Noto Lottie: `Noto/<codepoint>.json.xz`.
enum NotoLottieSource {
    /// ⚠️ **XZ, READ BY FOUNDATION.** The subset is 15 MB of JSON raw and
    /// 1.6 MB compressed; `NSData.decompressed(using: .lzma)` reads the XZ
    /// container `fetch_noto_subset.py` writes (verified against Python's
    /// `lzma` output), so no decompressor ships with the app.
    static func animation(codepoint: String, bundle: Bundle) -> LottieAnimation? {
        guard let data = jsonData(codepoint: codepoint, bundle: bundle) else { return nil }
        return try? LottieAnimation.from(data: data, strategy: .dictionaryBased)
    }

    static func jsonData(codepoint: String, bundle: Bundle) -> Data? {
        guard let url = bundle.url(
            forResource: codepoint, withExtension: "json.xz", subdirectory: EmoteCatalog.notoSubdirectory
        ), let compressed = try? Data(contentsOf: url) else { return nil }
        return try? (compressed as NSData).decompressed(using: .lzma) as Data
    }
}
