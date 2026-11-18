import DesignSystem
import UIKit

/// The danmaku band's geometry (#2380): the numbers its height is derived
/// from, moved out of the feed's band (`SnapCommentTickerView`) so the
/// action column (`SnapActionColumn`), which stands its bubbles the band's
/// height, reads the same ones without the band. The band reads them from
/// here too.
public enum CommentBandMetrics {
    /// The band's lanes.
    public static let laneCount = 2
    /// Between two lanes.
    public static let laneSpacing: CGFloat = 3
    /// Sized to fit within the lane (the band height is derived from the
    /// caption line + text insets, so a compact circle sits centered without
    /// growing the band).
    public static let bubbleAvatarDiameter: CGFloat = 20
    /// A bubble's text insets.
    public static let bubbleTextInsets = UIEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)

    /// One lane's height: it fits BOTH the caption line (+ insets) and the
    /// compact avatar, so a leading circle sits centered without growing the
    /// lane.
    @MainActor public static var laneBubbleHeight: CGFloat {
        max(
            bubbleAvatarDiameter,
            ceil(UIFont.appFont(forTextStyle: .caption1).lineHeight)
                + bubbleTextInsets.top + bubbleTextInsets.bottom
        )
    }

    /// The band's height in the current text size — what a band built now
    /// would report as its intrinsic height. The engagement corner's HEIGHT
    /// AUTHORITY (the boost anchor's square is this tall), stated without a
    /// band in hand, for a surface that has to stand a control the same size
    /// somewhere else (`SnapActionColumn`).
    @MainActor public static var bandHeight: CGFloat {
        CGFloat(laneCount) * laneBubbleHeight + CGFloat(laneCount - 1) * laneSpacing
    }
}
