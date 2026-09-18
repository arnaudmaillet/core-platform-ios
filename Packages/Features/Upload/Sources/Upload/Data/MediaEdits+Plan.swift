import Foundation
import MediaPlayback

extension MediaEdits {
    /// What a clip becomes: its pieces, its finish and its song, as the one
    /// value the preview plays and the publish path exports.
    ///
    /// ⚠️ **ONE MAPPING, TWO CONSUMERS, AND THAT IS THE POINT.** Written twice,
    /// the canvas and the post would agree only until one of them was changed —
    /// the rule `MediaTimelining.exportSegments` already states for the pieces,
    /// one level up.
    ///
    /// ⚠️ **THE EDITOR ASKS WITHOUT OVERLAYS AND WITHOUT ARTWORK.** Its canvas
    /// draws overlays as views; baking them into the preview too would draw each
    /// one twice. Publishing asks with both.
    ///
    /// `fileSeconds` is the FILE's real length, which the pieces are resolved
    /// against — the declared one can be wrong.
    func exportPlan(
        sourceURL: URL, fileSeconds: Double,
        artwork: (any OverlayArtwork)?, includingOverlays: Bool, includingCrop: Bool = true
    ) -> VideoExportPlan {
        VideoExportPlan(
            sourceURL: sourceURL,
            segments: MediaTimelining.exportSegments(timeline, withinSource: fileSeconds),
            finish: finish(includingOverlays: includingOverlays, includingCrop: includingCrop),
            soundtrack: soundtrack,
            artwork: artwork
        )
    }
}
