import CoreGraphics
import Foundation

/// Places posts into the chaotic layout's slots, matching each clip's shape to
/// the block that crops it least.
///
/// **What this replaces and why it still exists.** The mosaic had eight fixed
/// slot shapes, so `PostGridMosaic.arrangedForMotion` could match media to
/// bricks off a static table. A BSP tiling has no table: block shapes are
/// generated, they differ per slice, and they depend on the slice's own aspect.
/// The matching therefore reads the shapes the layout actually produced.
///
/// **Why matching is worth keeping at all.** `resizeAspectFill` crops by the
/// difference between the media's aspect and its container's, and the hero
/// flight then has to unwind that crop on the way to a full-screen page.
/// `PostGridFlightCard` flies a destination-sized surface under a uniform scale
/// specifically because that crop was small — a guarantee the old brick table
/// provided and this pass now provides instead. Without it a 9:16 clip can land
/// in a 4:3 block and take off through a hard crop.
public enum PostGridSliceArrangement {
    /// Aspect ratios closer than this are treated as the same shape.
    ///
    /// Used for the no-op guard: a window whose slots are all effectively the
    /// same shape has nowhere better to put anything, and arranging it would
    /// pull videos to the front of the page for no visual gain.
    private static let shapeEpsilon: CGFloat = 0.04

    /// Arranges `posts` into the slots at `absoluteIndex..<absoluteIndex + posts.count`.
    ///
    /// **Stability.** Placement is a pure function of the absolute slot shapes
    /// and of `posts` alone, so an item never moves once placed and a later page
    /// cannot disturb an earlier one — which is what lets the caller keep
    /// expressing a page landing as an insert rather than a reload.
    ///
    /// Nothing is dropped or duplicated. Stills keep their sequence outright;
    /// motion keeps its sequence only relative to the slots it claims, which is
    /// the same deliberate cost the mosaic's arrangement carried — a later
    /// portrait clip can precede an earlier landscape one once the layout is
    /// permuting order anyway.
    public static func arranged(
        _ posts: [GalleryPost],
        startingAt absoluteIndex: Int,
        slotMetrics: [SlotMetrics]
    ) -> [GalleryPost] {
        guard !posts.isEmpty else { return [] }
        // No shapes to match against — the host has not been laid out yet, or
        // the layout produced a shorter stack than the feed. Reading order is
        // the honest fallback; `onPlanInvalidated` re-runs this once geometry
        // resolves.
        guard slotMetrics.count >= absoluteIndex + posts.count, absoluteIndex >= 0 else {
            return posts
        }
        let slots = Array(slotMetrics[absoluteIndex..<(absoluteIndex + posts.count)])

        let motion = posts.filter(\.autoplaysInGrid)
        let stills = posts.filter { !$0.autoplaysInGrid }
        guard !motion.isEmpty, !stills.isEmpty else { return posts }

        // Every slot the same shape: nothing to gain, and rearranging would only
        // shuffle the page. Mirrors the mosaic's "a block covering only squares
        // has nowhere better to put a video" guard.
        let aspects = slots.map(\.aspect)
        if let low = aspects.min(), let high = aspects.max(), high - low < shapeEpsilon {
            return posts
        }

        var placed = [GalleryPost?](repeating: nil, count: posts.count)
        // Motion claims first, in order: each clip takes the free slot that
        // crops it least, breaking ties toward the larger block because motion
        // in a thumbnail-sized tile is noise rather than content.
        var overflow: [GalleryPost] = []
        for post in motion {
            if let offset = bestFreeSlot(for: post, in: slots, placed: placed) {
                placed[offset] = post
            } else {
                overflow.append(post)
            }
        }
        // Stills fill the holes in order, then anything motion could not claim.
        // The two counts match exactly, so no hole is left and nothing is lost.
        var remainder = stills + overflow
        for offset in placed.indices where placed[offset] == nil {
            placed[offset] = remainder.removeFirst()
        }
        return placed.compactMap(\.self)
    }

    /// The unclaimed slot whose shape is nearest the post's media.
    private static func bestFreeSlot(
        for post: GalleryPost, in slots: [SlotMetrics], placed: [GalleryPost?]
    ) -> Int? {
        let mediaAspect = CGFloat(post.aspectRatio > 0 ? post.aspectRatio : 1)
        var best: Int?
        var bestDistance = CGFloat.infinity
        var bestArea = -CGFloat.infinity
        for offset in slots.indices where placed[offset] == nil {
            let slot = slots[offset]
            // Compared in log space: aspect is a ratio, so 2:1 and 1:2 are
            // equally far from square and must score equally. Linear distance
            // would rate the wide one four times worse than the tall one.
            let distance = abs(log(max(slot.aspect, .leastNormalMagnitude)) - log(mediaAspect))
            if distance < bestDistance || (distance == bestDistance && slot.relativeArea > bestArea) {
                best = offset
                bestDistance = distance
                bestArea = slot.relativeArea
            }
        }
        return best
    }
}
