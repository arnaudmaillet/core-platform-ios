import Lottie
import UIKit

/// Turns stickers into `StickerStrip`s — PNG frames a compositor can read on
/// its own queue — and keeps the strips it made.
///
/// ⚠️ **LOTTIE DRAWS ON THE MAIN ACTOR ONLY**, and a compositor asks for frames
/// on its own queue 30 or 60 times a second. So frames are BAKED AHEAD of the
/// render: drawn here in short slices of the main actor, and encoded off it
/// while it is free again. A bake never holds the main thread for much more
/// than one frame's drawing.
///
/// ⚠️ **ONE FRAME CAN STILL BE HEAVY.** Drawing costs what the sticker holds,
/// not what the output measures. On a heavily loaded simulator Idea (253
/// layers) drew a 256px frame in about 8 ms and Snake (1,077 layers, 47 of them
/// masked gradients) in 100 ms or more. Bake before the strip is needed — when
/// a sticker is placed, not when the publish starts.
///
/// ⚠️ **30 FPS, PNG, AT MOST 384 PIXELS.** A sticker is 512px at 60fps; kept
/// raw that is about 176 MB each. Halving the rate, capping the side and
/// storing compressed bytes brings a loop down to a few megabytes, and a strip
/// holds one decoded frame at a time (`StickerStrip`).
@MainActor
public final class StickerFrameBaker: NSObject {
    /// How many frames a second a loop is baked at.
    public nonisolated static let framesPerSecond = 30
    /// The side the editor's canvas previews ask for.
    public nonisolated static let previewSide = 256
    /// The side a publish asks for, and the largest any bake is made at.
    public nonisolated static let exportSide = 384

    /// The baker the app shares, so a strip baked for the canvas is not baked
    /// again by the publish that follows.
    public static let shared = StickerFrameBaker()

    /// Whether a strip is the whole loop or its first frame alone.
    public enum Motion: Sendable {
        /// Every frame of one pass, at `framesPerSecond` — for a video.
        case loop
        /// The first frame only — for a photograph, which has no time.
        case still
    }

    private struct Key: Hashable {
        let id: String
        let side: Int
        let motion: Motion
    }

    /// How long frames are drawn in one go before the main actor is handed
    /// back: half a 60Hz frame. At least one frame is drawn per slice.
    static let slice = Duration.milliseconds(8)

    private var strips: [Key: StickerStrip] = [:]
    private var baking: [Key: Task<StickerStrip?, Never>] = [:]
    /// Bakes actually started — what `theBakerCaches` counts.
    private(set) var bakes = 0
    /// Frames drawn so far, across every bake — what a test watches from
    /// between two slices.
    private(set) var framesDrawn = 0

    override public init() {
        super.init()
        // A selector observer is dropped with its observer, so a baker made
        // for one publish leaves nothing registered behind.
        NotificationCenter.default.addObserver(
            self, selector: #selector(dropStrips),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
    }

    /// Strips are caches, never state: anything holding one keeps it alive,
    /// and everything else can be baked again.
    @objc private func dropStrips() {
        strips.removeAll()
    }

    /// The sticker's strip at `side` pixels (clamped to `1...exportSide`), baked
    /// on first request and shared after that. Nil when the sticker's file
    /// cannot be read.
    ///
    /// Two callers asking for the same strip while it bakes wait on ONE bake.
    public func strip(for sticker: Sticker, side: Int, motion: Motion = .loop) async -> StickerStrip? {
        let key = Key(id: sticker.id, side: Self.clampedSide(side), motion: motion)
        if let strip = strips[key] { return strip }
        if let running = baking[key] { return await running.value }
        let task = Task { await self.bake(sticker, side: key.side, motion: motion) }
        baking[key] = task
        let strip = await task.value
        baking[key] = nil
        if let strip { strips[key] = strip }
        return strip
    }

    /// The artwork a render needs for the stickers `ids` names, each baked at
    /// `side`. An identifier the catalogue does not know, or a sticker that
    /// fails to bake, is left out — the renderer then skips that sticker and
    /// draws everything else.
    public func artwork(for ids: some Sequence<String>, side: Int, motion: Motion = .loop) async -> StickerArtwork {
        var baked: [String: StickerStrip] = [:]
        for id in Set(ids) {
            guard let sticker = StickerCatalog.sticker(id: id),
                  let strip = await strip(for: sticker, side: side, motion: motion) else { continue }
            baked[id] = strip
        }
        return StickerArtwork(strips: baked)
    }

    private func bake(_ sticker: Sticker, side: Int, motion: Motion) async -> StickerStrip? {
        guard let file = await StickerCatalog.file(for: sticker) else { return nil }
        bakes += 1
        let drawer = StickerFrameDrawer(file: file, size: CGSize(width: side, height: side))
        guard drawer.duration > 0 else { return nil }
        let count = motion == .still ? 1 : Self.frameCount(forSeconds: drawer.duration)

        // One pixel per point: the context is `side` pixels square whatever the
        // screen, and 8 bits a channel, which is what PNG keeps small.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard

        let clock = ContinuousClock()
        var frames: [Data] = []
        frames.reserveCapacity(count)
        while frames.count < count {
            let started = clock.now
            var images: [CGImage] = []
            repeat {
                let seconds = Double(frames.count + images.count) / Double(Self.framesPerSecond)
                guard let image = drawer.image(atSeconds: seconds, format: format).cgImage else { return nil }
                images.append(image)
                framesDrawn += 1
            } while frames.count + images.count < count && clock.now - started < Self.slice
            // Awaiting the encode is what hands the main actor back between
            // slices.
            let encoded = await Task.detached(priority: .userInitiated) { [images] in
                images.compactMap(StickerStrip.png)
            }.value
            guard encoded.count == images.count else { return nil }
            frames += encoded
        }
        return StickerStrip(
            stickerID: sticker.id, side: side, framesPerSecond: Self.framesPerSecond,
            seconds: motion == .still ? 0 : drawer.duration, frames: frames
        )
    }

    /// Frames in one pass of `seconds`, sampled from 0 at `framesPerSecond`.
    ///
    /// ⚠️ **ROUNDED UP, WITH A HAIR OF SLACK.** A 179-frame animation at 60fps
    /// lasts 2.983s, which needs a 90th frame to be covered; a 3s one lasts
    /// exactly 90 frames, and `3.0 * 30` computed from a frame count may land a
    /// hair above 90 and must not become 91.
    nonisolated static func frameCount(forSeconds seconds: Double) -> Int {
        max(1, Int((seconds * Double(framesPerSecond) - 1e-6).rounded(.up)))
    }

    nonisolated static func clampedSide(_ side: Int) -> Int {
        min(max(side, 1), exportSide)
    }
}

/// A `.mainThread` Lottie view that draws one sticker at chosen times.
///
/// ⚠️ **THE MAIN THREAD ENGINE, DELIBERATELY, AND ONLY FOR DRAWING.** It draws
/// each frame into its own layers, which `render(in:)` can capture. The Core
/// Animation engine expresses frames as `CAAnimation`s over a sublayer tree,
/// and snapshotting that offscreen yields an empty image. On-screen playback
/// still uses Core Animation (`StickerKit.onScreenEngine`).
///
/// `render(in:)` redraws the vectors into the destination, so the layers'
/// own `contentsScale` does not matter here (measured: pixel-identical at 1
/// and 2, no faster).
@MainActor
final class StickerFrameDrawer {
    private let view = LottieAnimationView(configuration: LottieConfiguration(renderingEngine: .mainThread))
    /// Seconds in one pass of the animation.
    let duration: Double

    init(file: DotLottieFile, size: CGSize) {
        view.loadAnimation(from: file)
        view.contentMode = .scaleAspectFit
        view.frame = CGRect(origin: .zero, size: size)
        duration = view.animation?.duration ?? 0
    }

    /// The frame `seconds` into the pass, as big as the drawer, in `format`.
    func image(atSeconds seconds: Double, format: UIGraphicsImageRendererFormat) -> UIImage {
        view.currentTime = seconds
        view.layoutIfNeeded()
        view.forceDisplayUpdate()
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
    }
}
