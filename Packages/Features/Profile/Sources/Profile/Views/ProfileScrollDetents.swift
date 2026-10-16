import CoreGraphics
import PostGrid

/// Where a profile's scroll comes to rest while the header is still on
/// screen: a few positions the finger's release is drawn to, rather than
/// anywhere in between.
///
/// ```
///   band
///   0    ── top
///   N1   ── the avatar 40pt under the bar (a catching notch, #1208)
///   N    ── first post under the bar
/// ```
///
/// A header with no picture has the top and the first post.
///
/// Past the last detent the offset belongs to the list and is left alone.
enum ProfileScrollDetents {
    /// The detents, in the header's travelled space (0 at rest).
    static func detents(
        for format: ProfileBannerFormat, firstPost: CGFloat,
        bandAvatar: CGFloat? = nil
    ) -> [CGFloat] {
        var detents: [CGFloat] = [0]
        // ⚠️ EXPERIMENT (the owner, 2026-10-15): a band card rests with its
        // avatar just under the bar too.
        if format == .band, let bandAvatar, bandAvatar > 0, bandAvatar < firstPost {
            detents.append(bandAvatar)
        }
        if firstPost > 0 { detents.append(firstPost) }
        return detents
    }

    /// Where a release aimed at `target` should stop instead — the shared
    /// rule (`ScrollDetents`, PostGrid), which every hosted page applies.
    static func snapped(
        target: CGFloat, detents: [CGFloat], from: CGFloat? = nil, catching: [CGFloat] = []
    ) -> CGFloat? {
        ScrollDetents.snapped(target: target, detents: detents, from: from, catching: catching)
    }

    static var beyondSlack: CGFloat { ScrollDetents.beyondSlack }
}
