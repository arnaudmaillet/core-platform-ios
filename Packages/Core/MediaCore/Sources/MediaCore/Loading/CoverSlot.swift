import UIKit

/// A hero source's COVER on the loading ladder (#1088): the picture a grid
/// row, a tile or a card draws as its still, and the one a flight starts from.
///
/// The ladder's rules, without its hands on the view:
/// - drawn in the configure pass when the pipeline has it, dissolved in
///   (the picture, not the view) when it lands late;
/// - a new item cancels the load in flight, and a late answer for the old
///   one lands nowhere — a recycled host never shows the previous post;
/// - the same item again is a reconfigure and changes nothing (hook 8);
/// - a PARKED frame — the still a closing hero lands the host on — outranks
///   the pipeline's thumbnail landing after it (hook 7).
///
/// ⚠️ THE VIEW'S VISIBILITY AND ALPHA ARE NEVER TOUCHED (hooks 1 and 2). The
/// transitions read and conceal a hero source's cover by them, and a host's
/// cover can be the box its live surface and fill hang in, so the ladder
/// here keeps the state (item, rung, where the preview came from) and only
/// the picture changes.
@MainActor
public final class CoverSlot {
    /// The host's image view.
    public let view: UIImageView
    /// The cover's state: its item, its rung, where its preview came from.
    public let ladder: LoadingLadder
    /// Told when a cover that had to be fetched has landed — the autoplay
    /// waits on a cover to stand behind its first frame.
    public var onLoaded: (() -> Void)?
    /// Told whenever the cover changes picture, so a live surface keeps it as
    /// its poster.
    public var onChange: ((UIImage) -> Void)?
    /// Run in the same beat as the picture changes — inside its dissolve — for
    /// what the host derives from the picture (a page's framing, its blurred
    /// backdrop), so the two never arrive one after the other.
    public var alongside: ((UIImage) -> Void)?

    private let load: ImageLoadSlot
    private var url: URL?
    private weak var dissolving: UIView?

    /// - Parameters:
    ///   - size: the bucket the cover is decoded at — required (#894).
    ///   - dissolving: the view a late picture's dissolve runs over — the
    ///     image view by default; a page whose backdrop arrives with its
    ///     picture dissolves both together.
    public init(
        view: UIImageView, size: ImageBucket, dissolving: UIView? = nil,
        policy: LoadingLadder.Policy = .standard, clock: LoadingLadder.Clock = .system
    ) {
        self.view = view
        self.dissolving = dissolving
        load = ImageLoadSlot(size: size)
        ladder = LoadingLadder(policy: policy, clock: clock)
    }

    /// Shows `url`'s cover for `item` (the post).
    public func load(_ url: URL?, pipeline: ImagePipeline?, item: AnyHashable) {
        if item == ladder.item, url == self.url, load.isLoading || ladder.rung != nil { return }
        let token = ladder.begin(item: item)
        self.url = url
        view.image = nil
        load.load(url, using: pipeline) { [weak self] image, transition in
            guard let self, ladder.isCurrent(token) else { return }
            // A parked frame put meanwhile is the better picture (hook 7).
            guard ladder.previewSource != .parked else { return }
            ladder.show(.preview, token: token, warm: transition == .none)
            transition.perform(on: dissolving ?? view) { [weak self] in self?.draw(image) }
            onChange?(image)
            if transition != .none { onLoaded?() }
        } failed: { [weak self] in
            guard let self, ladder.isCurrent(token) else { return }
            ladder.fail(token: token)
        }
    }

    /// A cover handed in from outside the pipeline (a seed, a stand-in):
    /// used only when there is none yet.
    public func apply(_ image: UIImage) {
        guard view.image == nil else { return }
        draw(image)
        ladder.show(.preview, token: ladder.currentToken, warm: true)
        onChange?(image)
    }

    /// The frame a closing hero lands the host on: it replaces the cover, and
    /// the thumbnail still loading is dropped (hook 7).
    public func showParked(_ image: UIImage) {
        draw(image)
        ladder.show(.preview, token: ladder.currentToken, warm: true, source: .parked)
        onChange?(image)
    }

    /// Back to no cover — a recycled host, or one with nothing to draw: the
    /// load in flight lands nowhere.
    public func reset() {
        load.cancel()
        url = nil
        view.image = nil
        ladder.begin(item: nil)
    }

    private func draw(_ image: UIImage) {
        view.image = image
        alongside?(image)
    }

    /// What the host draws as its still now.
    public var image: UIImage? { view.image }

    /// Whether a cover load is in flight.
    public var isLoading: Bool { load.isLoading }
}
