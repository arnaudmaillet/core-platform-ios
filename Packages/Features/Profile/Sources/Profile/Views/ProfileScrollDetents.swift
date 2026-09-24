import CoreGraphics

/// Where a profile's scroll comes to rest while the header is still on
/// screen: a few positions the finger's release is drawn to, rather than
/// anywhere in between.
///
/// ```
///   poster                 band
///   0    ── top, picture   0    ── top (the avatar is already under the chrome)
///   188  ── avatar under   ·
///          the chrome,
///          poster gone
///   N    ── first post     N    ── first post under the bar
///          under the bar
/// ```
///
/// A poster has three: the picture, the identity with the picture gone
/// (exactly where the band would hold the avatar, so the two shapes meet),
/// and the first post. A band has two, since its top IS the second.
///
/// Past the last detent the offset belongs to the list and is left alone.
enum ProfileScrollDetents {
    /// The detents, in the header's travelled space (0 at rest).
    static func detents(
        for format: ProfileBannerFormat, posterFadeOut: CGFloat, firstPost: CGFloat
    ) -> [CGFloat] {
        var detents: [CGFloat] = [0]
        if format == .poster, posterFadeOut > 0, posterFadeOut < firstPost {
            detents.append(posterFadeOut)
        }
        if firstPost > 0 { detents.append(firstPost) }
        return detents
    }

    /// Where a release aimed at `target` should stop instead, or nil where
    /// the offset is the list's own: above the top (a pull) or past the last
    /// detent.
    ///
    /// The NEAREST detent to where the scroll would have stopped, not the
    /// next one in the direction of travel: the target already carries the
    /// fling's momentum, so a short flick that would have stopped just past
    /// a detent lands on it, and a long one that would have cleared the next
    /// lands there.
    static func snapped(target: CGFloat, detents: [CGFloat]) -> CGFloat? {
        guard let last = detents.last, target >= 0, target <= last + beyondSlack else { return nil }
        if target >= last { return last }
        return detents.min { abs($0 - target) < abs($1 - target) }
    }

    /// How far past the last detent a release may be heading and still be
    /// drawn back onto it. A flick from the top that would have run a little
    /// into the list stops at the first post instead — that is what the
    /// detent is for — while a flick that clears it by more is a scroll of
    /// the list and is left alone.
    static let beyondSlack: CGFloat = 100
}
