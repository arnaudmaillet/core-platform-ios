import MediaPlayback
import UIKit

/// A marker that can host a live preview.
///
/// It exists because the coordinator only ever needed a place to draw, and
/// typing that place as `MapAnnotationView` quietly excluded every cluster.
/// `MapClusterAnnotationView` hosts the same `PinCardView` and therefore has the
/// same surface — but it could not be a candidate, and cluster representatives
/// are chosen by like count and are KIND-NEUTRAL, so a video post leading a
/// group silently never played.
///
/// ⚠️ That was not a rare edge. On the mock corpus every video pin in the
/// default viewport was inside a cluster, so the playback path had literally
/// never run: `-maps-force-video` produced zero playing videos and the "at most
/// 3" guarantee had never been exercised.
@MainActor
protocol MapVideoHost: AnyObject {
    /// The surface the pool draws into.
    var videoRenderView: VideoRenderView { get }
    /// Reveals the surface, seeded with the still already on screen so the
    /// marker never shows a black frame while the first video frame decodes.
    func beginVideoPreview()
    /// Hides it and clears back to the still.
    func endVideoPreview()
    /// Fired when MapKit recycles the marker, so a bound player goes back to
    /// the pool before the view is handed to a different post.
    var onReuse: (() -> Void)? { get set }
}
