import CoreGraphics

/// Where an empty tab's message sits on the profile.
///
/// Arithmetic, pulled out of the grid, because the failure it exists to prevent
/// depends on the SCREEN and so cannot be seen on the device you are developing
/// on: the block is centred between the header's bottom and the chrome at the
/// foot of the screen, and on a short phone that band is smaller than the block.
enum ProfileEmptyStatePlacement {
    /// The block's centre, in the page's own coordinates.
    ///
    /// ⚠️ **Centred, but never above the band's top.** Centring alone assumes
    /// the band is taller than the block. Measured on iPhone SE 3, a pushed
    /// profile leaves `564 … 573` — nine points — for a 99pt block, so the
    /// centre put the block's glyph 45pt ABOVE the header's bottom edge, behind
    /// the tab selector, which is the last thing drawn there. Arnaud reported
    /// exactly that.
    ///
    /// When the band cannot hold the block, the block starts where the first row
    /// would and the viewer reaches the rest the same way they would reach a
    /// second row — by scrolling, which this profile's header is built to do.
    /// Where the band HAS the room nothing changes: iPhone 17 leaves 174pt for
    /// the same block and the centre wins.
    static func centreY(
        visibleTop: CGFloat, visibleBottom: CGFloat, blockHeight: CGFloat
    ) -> CGFloat {
        let centred = (visibleTop + max(visibleTop, visibleBottom)) / 2
        let flushWithTop = visibleTop + blockHeight / 2
        return max(centred, flushWithTop)
    }
}
