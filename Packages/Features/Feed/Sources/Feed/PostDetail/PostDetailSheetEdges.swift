import DesignSystem
import ThreadKit
import UIKit

/// What the sheet's edges ask of their panel (#2523): the composer, which
/// stands as the bottom edge's pocket and ends the clip, the streams and
/// the one on screen, and the surface that moves and hides them.
@MainActor
protocol PostDetailSheetEdgesHost: AnyObject {
    var composeBar: CommentsInputBar { get }
    var streams: [CommentStream] { get }
    var stream: CommentStream { get }
    var streamSurface: UIView { get }
}

/// The comments sheet's edges and the streams' clip at the composer
/// (#2087), out of `PostDetailViewController` (#2523).
///
/// ⚠️ ITS CALLER PICKS THE TIME: `SnapCommentsSheet` wears the edges once
/// the panel is on a window and clips the streams as the keyboard comes
/// and goes; the panel's `viewDidLayoutSubviews` re-syncs the clip in its
/// layout pass, inside a keyboard's animation when one runs it. Every
/// entry point runs in the caller's turn.
@MainActor
final class PostDetailSheetEdges {
    private unowned let host: any PostDetailSheetEdgesHost

    init(host: any PostDetailSheetEdgesHost) {
        self.host = host
    }

    // MARK: - The comments sheet's edges (#2087)

    /// Whether the panel wears the sheet's edges (`wearSheetEdges`).
    private var wearsSheetEdges = false
    /// The composer as the pocket over the visible list's bottom edge.
    private let sheetEdgePocket = UIScrollEdgeElementContainerInteraction()

    /// The visible stream changed (`visibleStreamDidChange`): the pocket
    /// follows it, once the panel wears the sheet's edges.
    func streamDidChange() {
        if wearsSheetEdges { sheetEdgePocket.scrollView = host.stream.collectionView }
    }

    /// A stream its room holds whole does not scroll at all, so a drag on it
    /// is the sheet's own — the sheet stretches and springs back, as it does
    /// under the grabber (#2087, the owner 2026-11-03). A longer stream
    /// scrolls, as any list.
    func letSheetTakeShortStreams() {
        host.streams.forEach { $0.collectionView.alwaysBounceVertical = false }
    }

    /// The comments sheet's edges: UIKit's own SOFT edge effects, as the
    /// app's other lists wear them (the owner, 2026-11-03) — the top one
    /// under the sheet's bar, a titled screen's (`prefersSoftTopEdge`), the
    /// bottom one under the composer, which stands over the visible list's
    /// bottom edge as its pocket: `BottomEdgeBlurView`'s mechanism, the
    /// composer being the content over the edge. The host's bar tracks
    /// `stream.collectionView` (`onVisibleStreamChange`).
    ///
    /// ⚠️ On a window, not before: touching an edge effect materialises Liquid
    /// Glass machinery (`StatusBarBlurView`).
    func wearSheetEdges() {
        guard !wearsSheetEdges else { return }
        wearsSheetEdges = true
        for stream in host.streams {
            // ⚠️ WITHOUT THE FADE'S CLEARANCE (#2240): the stream owns its
            // top inset — its shapes (#2195) and the short stream's anchor
            // re-assert it whenever it differs — so a clearance topped up
            // under it would be undone and re-added on every pass. Its
            // shapes would have to count the fade themselves.
            stream.collectionView.prefersSoftTopEdge(keepsContentBelowFade: false)
            stream.collectionView.bottomEdgeEffect.isHidden = false
            stream.collectionView.bottomEdgeEffect.style = .soft
        }
        sheetEdgePocket.edge = .bottom
        sheetEdgePocket.scrollView = host.stream.collectionView
        host.composeBar.addInteraction(sheetEdgePocket)
    }

    /// Whether the streams end at the composer's foot (`setStreamsClippedAtComposer`).
    private var clipsStreamsAtComposer = false
    /// How far below the composer's foot the clipped streams end.
    private var streamsClipBelowComposer: CGFloat = 0
    private let streamsClip = UIView()

    /// The streams end at the composer's foot, or run to the panel's bottom,
    /// under the composer and its soft edge (the comments sheet, #2087). Clipped
    /// while a keyboard is up only: the composer then moves within the sheet,
    /// and rows were seen passing beneath it, in the band it leaves; at rest
    /// the rows run to the sheet's foot (the owner, 2026-11-03).
    ///
    /// ⚠️ `below` CARRIES THEM ON UNDER THE KEYS (the owner, 2026-11-04): the
    /// keyboard's top corners are rounded, and rows ending at the composer's
    /// foot left a plain band there, its edge seen in the corners. Below the
    /// composer they pass under its soft edge, at its fullest there.
    func setStreamsClippedAtComposer(_ clipped: Bool, below: CGFloat = 0) {
        guard clipped != clipsStreamsAtComposer else { return }
        clipsStreamsAtComposer = clipped
        streamsClipBelowComposer = below
        streamsClip.backgroundColor = .black
        // ⚠️ THE CLIP STARTS WHERE THE STREAMS ARE, NOT AT ZERO (measured,
        // 2026-11-03): set inside the keyboard's animation, a clip born empty
        // grew from nothing — the rows vanished, then came back from the top
        // down, a flash at every keyboard. Its frame is set unanimated first.
        UIView.performWithoutAnimation {
            syncStreamsClip()
            host.streamSurface.mask = clipped ? streamsClip : nil
        }
    }

    /// The clip to the composer's foot, in this layout pass — inside a
    /// keyboard's animation when one runs it, so the two move together.
    func syncStreamsClip() {
        guard clipsStreamsAtComposer, host.streamSurface.bounds.width > 0 else { return }
        let foot = host.composeBar.convert(host.composeBar.bounds, to: host.streamSurface).maxY + streamsClipBelowComposer
        streamsClip.frame = CGRect(x: 0, y: 0, width: host.streamSurface.bounds.width, height: max(0, foot))
    }
}

extension PostDetailViewController: PostDetailSheetEdgesHost {}
