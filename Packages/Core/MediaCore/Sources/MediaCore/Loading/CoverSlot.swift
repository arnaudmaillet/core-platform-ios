import DesignSystem
import UIKit

/// A hero source's COVER on the loading ladder (#1088): the picture a grid
/// row, a tile or a card draws as its still, and the one a flight starts from
/// — the media slot's contract (#1505), without its hands on the view:
/// - drawn in the configure pass when the pipeline has it;
/// - not in memory: nothing for `skeletonDelay`, then the BONE (`bone`, in
///   the cover, under its picture), held at least `skeletonMinimum`, then
///   the picture dissolved in over it — never a flat fill and a snap (the
///   owner's recordings, 2026-10-21);
/// - a new item cancels the load in flight, and a late answer for the old
///   one lands nowhere — a recycled host never shows the previous post;
/// - the same item again is a reconfigure and changes nothing (hook 8);
/// - a PARKED frame — the still a closing hero lands the host on — outranks
///   the pipeline's thumbnail landing after it (hook 7).
///
/// ⚠️ THE VIEW'S VISIBILITY AND ALPHA ARE NEVER TOUCHED (hooks 1 and 2). The
/// transitions read and conceal a hero source's cover by them, and a host's
/// cover can be the box its live surface and fill hang in, so the ladder
/// here keeps the state (item, rung, where the preview came from), shows and
/// hides only the bone, and the picture is drawn as its rung lands
/// (`LoadingLadder.onLand`).
///
/// ⚠️ THE BONE IS A SUBVIEW OF THE COVER, at its back: an image view draws
/// its picture under its subviews, so the bone covers the cover's own fill
/// (the card's grey, a video's dark) and leaves as the picture lands — in
/// the same dissolve, which runs over the cover's whole tree.
@MainActor
public final class CoverSlot {
    /// The host's image view.
    public let view: UIImageView
    /// The cover's state: its item, its rung, where its preview came from.
    public var ladder: LoadingLadder { slot.ladder }
    /// The bone shown while a cover not in memory is on its way — in the
    /// cover, at its back, edge to edge (the host's clip rounds it).
    public let bone = SkeletonBoneView(rounding: .fixed(0))
    /// Told when a cover that had to be fetched has landed — the autoplay
    /// waits on a cover to stand behind its first frame.
    public var onLoaded: (() -> Void)?
    /// Told when the cover's load failed: a host showing a skeleton while it
    /// waits stills it (#1553) rather than shimmering forever.
    public var onFailed: (() -> Void)?
    /// Told whenever the cover changes picture, so a live surface keeps it as
    /// its poster.
    public var onChange: ((UIImage) -> Void)?
    /// Run in the same beat as the picture changes — inside its dissolve — for
    /// what the host derives from the picture (a page's framing, its blurred
    /// backdrop), so the two never arrive one after the other.
    public var alongside: ((UIImage) -> Void)?

    private let slot: MediaSlot
    private var url: URL?
    private weak var dissolving: UIView?
    /// The picture whose rung is about to land, and whether it was fetched.
    private var pending: (image: UIImage, fetched: Bool)?

    /// - Parameters:
    ///   - size: the bucket the cover is decoded at — required (#894).
    ///   - dissolving: the view a late picture's dissolve runs over — the
    ///     image view by default; a page whose backdrop arrives with its
    ///     picture dissolves both together. It must hold the cover.
    public init(
        view: UIImageView, size: ImageBucket, dissolving: UIView? = nil,
        policy: LoadingLadder.Policy = .standard, clock: LoadingLadder.Clock = .system
    ) {
        self.view = view
        self.dissolving = dissolving
        bone.frame = view.bounds
        bone.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(bone, at: 0)
        slot = MediaSlot(size: size, bone: bone, policy: policy, clock: clock)
        ladder.onLand = { [weak self] rung, transition in
            guard rung == .preview else { return }
            self?.landed(transition)
        }
    }

    /// Shows `url`'s cover for `item` (the post).
    public func load(_ url: URL?, pipeline: ImagePipeline?, item: AnyHashable) {
        if item == ladder.item, url == self.url, slot.isLoading || pending != nil || view.image != nil { return }
        slot.begin(item)
        self.url = url
        pending = nil
        view.image = nil
        slot.load(url, using: pipeline) { [weak self] image, transition in
            guard let self else { return }
            // A parked frame put meanwhile is the better picture (hook 7).
            guard ladder.previewSource != .parked else { return }
            pending = (image, transition != .none)
            // Lands now when warm, else once the bone has had its minimum.
            ladder.show(.preview, token: slot.token, warm: transition == .none)
        } failed: { [weak self] in
            self?.onFailed?()
        }
    }

    /// A cover handed in from outside the pipeline (a seed, a stand-in):
    /// used only when there is none yet.
    public func apply(_ image: UIImage) {
        // A fetched cover waiting out the bone's minimum is on its way, and
        // is the better picture.
        guard view.image == nil, pending == nil else { return }
        pending = (image, false)
        ladder.show(.preview, token: ladder.currentToken, warm: true)
    }

    /// The frame a closing hero lands the host on: it replaces the cover, and
    /// the thumbnail still loading is dropped (hook 7).
    public func showParked(_ image: UIImage) {
        // A fetched cover it replaces, still waiting out the bone's minimum,
        // was loaded all the same: the autoplay waiting on it is told.
        pending = (image, pending?.fetched ?? false)
        ladder.show(.preview, token: ladder.currentToken, warm: true, source: .parked)
    }

    /// Back to no cover — a recycled host, or one with nothing to draw: the
    /// load in flight lands nowhere.
    public func reset() {
        slot.cancel()
        slot.begin(nil)
        url = nil
        pending = nil
        view.image = nil
    }

    /// The preview rung lands: its picture is drawn, in the ladder's
    /// transition — the bone leaving in the same pass, under the dissolve.
    private func landed(_ transition: LoadingLadder.Transition) {
        guard let (image, fetched) = pending else { return }
        pending = nil
        transition.perform(on: dissolving ?? view) { [weak self] in self?.draw(image) }
        onChange?(image)
        if fetched { onLoaded?() }
    }

    private func draw(_ image: UIImage) {
        view.image = image
        alongside?(image)
    }

    /// What the host draws as its still now.
    public var image: UIImage? { view.image }

    /// Whether a cover is on its way: loading, or landed and waiting out the
    /// bone's minimum.
    public var isLoading: Bool { slot.isLoading || pending != nil }

    #if DEBUG
    /// Whether the bone shows now.
    public var debugShowsBone: Bool { slot.showsBone }
    /// Whether a picture has arrived and waits for its rung to land.
    var debugHasPending: Bool { pending != nil }
    #endif
}
