import CoreGraphics

/// Where a page hosted under a floating header puts its empty or failed
/// state: in the room between the header and the chrome at the screen's foot
/// — shared by every hosted page through `ForYouGridPage` (#1273), the
/// profile's rule (`ProfileEmptyStatePlacement`).
public enum HostedStatusPlacement {
    /// The block's centre, in the page's own coordinates.
    ///
    /// ⚠️ **Centred, but never above the band's top.** Centring alone assumes
    /// the band is taller than the block. Measured on iPhone SE 3, a pushed
    /// profile leaves `564 … 573` — nine points — for a 99pt block, so the
    /// centre put the block's glyph 45pt ABOVE the header's bottom edge,
    /// behind the tab selector. When the band cannot hold the block, the block
    /// starts where the first row would, and the viewer scrolls to the rest.
    public static func centreY(
        visibleTop: CGFloat, visibleBottom: CGFloat, blockHeight: CGFloat
    ) -> CGFloat {
        let centred = (visibleTop + max(visibleTop, visibleBottom)) / 2
        let flushWithTop = visibleTop + blockHeight / 2
        return max(centred, flushWithTop)
    }
}
