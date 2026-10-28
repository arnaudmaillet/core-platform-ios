import CoreGraphics

/// Where the loader's three pills stand (#1795): side by side, centred in the
/// loader's square, each a dot at rest that grows into a taller pill and back.
///
/// A pill's width is what three pills and their two gaps (each
/// `gapRatio` × the width) take across the square; its height runs from the
/// width (a dot, a circle) at rest to `peakRatio` × the width at its peak.
/// At `.large` (37 pt) that is ≈ 10.3 pt × 25.7 pt at the peak; at `.medium`
/// (20 pt), ≈ 5.6 pt × 13.9 pt.
public enum AppLoaderGeometry {
    /// Three pills, the brand gradient across them (`Palette.loaderTones`).
    public static let pillCount = 3
    /// The gap between two pills, as a share of a pill's width.
    public static let gapRatio: CGFloat = 0.3
    /// The tallest a pill grows, as a multiple of its width (the owner's
    /// reference was 5.7×: too tall).
    public static let peakRatio: CGFloat = 2.5

    /// A pill's width in a loader `side` wide.
    public static func pillWidth(side: CGFloat) -> CGFloat {
        side / (CGFloat(pillCount) + CGFloat(pillCount - 1) * gapRatio)
    }

    /// Pill `index`'s frame in a loader `side` wide, `height` of the way from
    /// a dot (0) to its peak (1), centred vertically.
    public static func pillFrame(_ index: Int, height: CGFloat, side: CGFloat) -> CGRect {
        let width = pillWidth(side: side)
        let tall = width * (1 + (peakRatio - 1) * min(1, max(0, height)))
        let x = CGFloat(index) * width * (1 + gapRatio)
        return CGRect(x: x, y: (side - tall) / 2, width: width, height: tall)
    }

    /// A pill's height in points, `height` of the way from a dot to its peak.
    public static func pillHeight(_ height: CGFloat, side: CGFloat) -> CGFloat {
        pillFrame(0, height: height, side: side).height
    }
}
