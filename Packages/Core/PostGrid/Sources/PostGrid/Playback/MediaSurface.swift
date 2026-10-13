import MediaCore
import MediaPlayback
import UIKit

/// THE MEDIA SURFACE (#1088, step 4 of #1085): a cover, and a live video
/// surface over it — the one place a grid host wires "cover first, then the
/// first frame" instead of each writing it again.
///
/// ```
///   host's ground (the card fill)
///   cover   (UIImageView) — the ladder's PREVIEW rung, a permanent floor
///   surface (VideoRenderView) — revealed on its first frame, by itself
///   host's chrome (captions, counters) above
/// ```
///
/// Two halves, and they are kept apart on purpose:
/// - **The cover's arrival is the ladder's** (`LoadingLadder`): drawn in the
///   configure pass when the pipeline has it, dissolved in when it lands, a
///   recycled host never showing the previous post's, and a PARKED frame —
///   the still a closing hero lands the tile on — outranking the pipeline's
///   thumbnail that arrives after it (the ladder's hook 7).
/// - **Playback is not a loading step.** A preview starts and stops again
///   and again on one post, which the ladder (monotonic within an item) is
///   not for. The surface's own reveal (`revealOnFirstFrame`,
///   `hideCrossFading`) keeps its alpha — one driver per alpha (hook 2) — and
///   this type only does the plumbing every host copied: build it above the
///   cover, adopt one lent in, donate it out, keep its poster the cover.
///
/// The views stay the host's and stay addressable (hook 1): `cover` is the
/// host's image view, `video` the surface it holds; the hero reads them as
/// it always did.
@MainActor
public final class MediaSurface {
    /// The cover — the host's own image view.
    public let cover: UIImageView
    /// The live surface, once built or adopted.
    public private(set) var video: VideoRenderView?
    /// The cover's ladder (its arrival only).
    public let ladder: LoadingLadder
    /// Told when a cover that had to be fetched has landed — the autoplay
    /// waits on a cover to stand behind its first frame.
    public var onCoverLoaded: (() -> Void)?
    /// The surface's label in the playback logs (DEBUG).
    public var debugLabel: String?

    private weak var host: UIView?
    private let load: ImageLoadSlot

    /// - Parameters:
    ///   - cover: the host's image view, already laid out in `host`.
    ///   - host: where the surface is inserted, just above the cover.
    ///   - coverSize: the bucket the cover is decoded at — required (#894).
    public init(
        cover: UIImageView, in host: UIView, coverSize: ImageBucket,
        policy: LoadingLadder.Policy = .standard, clock: LoadingLadder.Clock = .system
    ) {
        self.cover = cover
        self.host = host
        load = ImageLoadSlot(size: coverSize)
        ladder = LoadingLadder(policy: policy, clock: clock)
        // The cover's alpha is not the ladder's: a hero source's cover is
        // read and concealed by the transitions (hook 2), so its arrival is a
        // dissolve of the picture, not a fade of the view.
        ladder.setView(cover, for: .preview, drivesAlpha: false, permanent: true)
    }

    // MARK: - The cover

    /// Shows `url`'s cover for `item` (the post): drawn now when the pipeline
    /// has it, else dissolved in when it lands — the live surface's poster
    /// follows it. The same item again is a reconfigure and changes nothing
    /// in flight; another cuts.
    public func loadCover(_ url: URL?, pipeline: ImagePipeline?, item: AnyHashable) {
        if item == ladder.item, url == load.url, load.isLoading || ladder.rung != nil { return }
        let token = ladder.begin(item: item)
        cover.image = nil
        load.load(url, using: pipeline) { [weak self] image, transition in
            guard let self, ladder.isCurrent(token) else { return }
            // A parked frame put meanwhile is the better picture (hook 7).
            guard ladder.previewSource != .parked else { return }
            // Unhidden first, so the picture dissolves in on a visible view.
            ladder.show(.preview, token: token, warm: transition == .none)
            transition.perform(on: cover) { [cover] in cover.image = image }
            video?.setPoster(image)
            if transition != .none { onCoverLoaded?() }
        } failed: { [weak self] in
            guard let self, ladder.isCurrent(token) else { return }
            ladder.fail(token: token)
        }
    }

    /// A cover handed in from outside the pipeline (a seed, a stand-in):
    /// used only when there is none yet.
    public func applyCover(_ image: UIImage) {
        guard cover.image == nil else { return }
        cover.image = image
        ladder.show(.preview, token: ladder.currentToken, warm: true)
        video?.setPoster(image)
    }

    /// The frame a closing hero lands the host on, taken as its cover: it
    /// outranks the pipeline's thumbnail landing later (hook 7).
    public func showReturnStill(_ image: UIImage) {
        cover.image = image
        ladder.show(.preview, token: ladder.currentToken, warm: true, source: .parked)
        video?.setPoster(image)
    }

    /// Whether a cover load is in flight.
    public var isLoadingCover: Bool { load.isLoading }

    /// What the host draws as its still now.
    public var renderedCover: UIImage? { cover.image }

    /// Back to nothing — a recycled host's first step: the load in flight
    /// lands nowhere.
    public func reset() {
        load.cancel()
        cover.image = nil
        ladder.begin(item: nil)
    }

    // MARK: - The surface

    /// The surface, built on first use: hidden, above the cover, below the
    /// host's chrome — the words read over moving video as over a poster.
    public func makeVideoRenderViewIfNeeded() -> VideoRenderView {
        if let video { return video }
        let view = VideoRenderView()
        #if DEBUG
        if let debugLabel { view.debugLabel = debugLabel }
        #endif
        view.isHidden = true
        view.isUserInteractionEnabled = false
        place(view)
        video = view
        return view
    }

    /// A surface lent in (a landing hero's, the coordinator's): it replaces
    /// the one held, shown at once — it is already drawing.
    public func adopt(_ view: VideoRenderView) {
        if let existing = video, existing !== view {
            existing.detachForReplacement()
            existing.removeFromSuperview()
        }
        view.transform = .identity
        view.isHidden = false
        place(view)
        video = view
    }

    /// Hands the surface out (to a flight card): the host keeps its cover.
    public func donate() -> VideoRenderView? {
        guard let view = video else { return nil }
        video = nil
        view.removeFromSuperview()
        return view
    }

    /// The preview starts: the cover stays until there is a frame to
    /// replace it with (the surface's own reveal).
    public func beginPreview() {
        let view = makeVideoRenderViewIfNeeded()
        view.setPoster(cover.image)
        view.revealOnFirstFrame()
    }

    /// The preview stops: the surface fades off the cover.
    public func endPreview() {
        video?.hideCrossFading()
    }

    private func place(_ view: VideoRenderView) {
        guard let host else { return }
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if cover.superview === host {
            host.insertSubview(view, aboveSubview: cover)
        } else {
            host.addSubview(view)
        }
    }
}
