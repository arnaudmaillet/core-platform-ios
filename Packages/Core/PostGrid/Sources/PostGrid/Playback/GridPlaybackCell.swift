import MediaPlayback
import UIKit

/// What the playback coordinator needs from a cell in order to autoplay it.
///
/// Extracted when the timeline's LIST ROWS were given autoplay. Until then the
/// coordinator named `PostGridTileCell` directly, which was honest — the mosaic
/// was the only surface that played — but a row is a different shape with the
/// same job: it owns a media box, it can hold a render surface inside it, and
/// it gets recycled out from under a player. Only those facts matter here, and
/// they are the whole protocol.
///
/// The two conformances differ in exactly one structural way, and it is why
/// this is a protocol rather than a shared superclass: a TILE is its media, so
/// its surface fills `contentView`; a ROW is a card of which the media is one
/// part, so its surface lives inside the preview box and inherits that box's
/// rounding and its concealment. Each cell places its own surface; nothing out
/// here knows where the media is.
@MainActor
public protocol GridPlaybackCell: UIView {
    /// Where the video lives inside this cell, in the cell's own coordinates.
    ///
    /// The one question whose ANSWER differs by shape while the question does
    /// not, so the cell answers it and no caller switches on a type. A tile IS
    /// its media, so this is its bounds; a row is a card of which the media is
    /// one part, so this is the preview box.
    ///
    /// It is what visibility is measured against, and measuring the CARD
    /// instead is wrong in both directions: a row leaving the top keeps half
    /// its area on screen long after the video has gone, and one arriving from
    /// the bottom passes on caption alone with the preview still below the
    /// fold. Both are the wrong answer to "is the viewer looking at this
    /// video".
    var videoMediaRect: CGRect { get }

    /// The image the cell is currently showing. Autoplay is gated on this: a
    /// surface with no cover behind it draws black until the first frame
    /// decodes.
    var renderedCover: UIImage? { get }

    /// Puts a cover on immediately, ahead of any load already in flight.
    func applyCover(_ image: UIImage)

    /// Fired when a cover lands from an async load, so the gate above can be
    /// re-run. Without it a cell whose cover arrives while the surface is
    /// stationary fails the gate once and is never asked again.
    var onCoverLoaded: (() -> Void)? { get set }

    /// The surface to render into, built on first use.
    ///
    /// Deliberately not a `lazy var`: the coordinator asks whether a cell
    /// *could* be playing via `loadedVideoRenderView`, and that question must
    /// not itself allocate a player layer.
    func makeVideoRenderViewIfNeeded() -> VideoRenderView

    /// The surface if one was ever built, else nil — never allocates.
    var loadedVideoRenderView: VideoRenderView? { get }

    /// Whether the playback surface is showing the media the viewer is looking
    /// at RIGHT NOW.
    ///
    /// ⚠️ It exists for the hero flight, and it exists because "this cell is
    /// playing" stopped meaning "this cell's picture is moving".
    ///
    /// A row holds its player while the viewer pages onto a still of the same
    /// collection — the clip keeps its last frame on its own page, which is
    /// still on screen peeking. A flight that took that surface would carry a
    /// photograph the viewer is not looking at into the transition: reported as
    /// "the hero animation uses the video as its window even though I had paged
    /// past it".
    ///
    /// A tile and a single-attachment row have one piece of media, so their
    /// answer is simply whether a surface exists.
    var isRenderingCurrentMedia: Bool { get }

    /// Installs a flight card's live surface as this cell's own, at landing.
    func adoptVideoRenderView(_ view: VideoRenderView)

    /// Gives up the live surface so a flight can carry the *same* layer.
    func donateVideoRenderView() -> VideoRenderView?

    /// Reveals the surface once a player is attached, keeping the cover behind
    /// it as the poster.
    func beginVideoPreview()

    /// Back to a still cell.
    func endVideoPreview()

    /// Called when the collection view recycles this cell, so whoever loaned it
    /// a player takes it back. A recycled cell that kept its loan would render
    /// the previous post's video under the new post's cover.
    var onReuse: (() -> Void)? { get set }

    /// Every surface this cell is holding a player on.
    ///
    /// ⚠️ NOT the same question as `loadedVideoRenderView`, and the difference is
    /// what makes a loan releasable. A cell with a collection can keep a paused
    /// clip on a page the viewer left, so "the surface" and "the surfaces" stop
    /// being the same set — and a release that stopped only the watched one
    /// would leave the rest bound to players nobody is tracking.
    var retainedPlaybackSurfaces: [VideoRenderView] { get }

    /// Keeps at most `budget` extra clips warm besides the one being watched,
    /// and reports the surfaces it gave up so the caller can end their playback.
    ///
    /// A budget of zero is the old behaviour exactly: one clip at a time.
    @discardableResult
    func retainClips(budget: Int) -> [VideoRenderView]

    /// Gives up every kept clip but the watched one, reporting them.
    @discardableResult
    func releaseRetainedClips() -> [VideoRenderView]
}

public extension GridPlaybackCell {
    /// A cell that draws one attachment holds one surface, and there is nothing
    /// for a window to choose between.
    var retainedPlaybackSurfaces: [VideoRenderView] {
        loadedVideoRenderView.map { [$0] } ?? []
    }

    @discardableResult
    func retainClips(budget: Int) -> [VideoRenderView] { [] }

    @discardableResult
    func releaseRetainedClips() -> [VideoRenderView] { [] }
}
