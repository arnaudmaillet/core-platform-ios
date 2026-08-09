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
}
