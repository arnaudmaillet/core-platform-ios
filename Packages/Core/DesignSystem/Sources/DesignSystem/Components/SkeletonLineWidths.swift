import CoreGraphics

/// THE width rule of every list skeleton (#1774): a row's text bones take
/// these fractions of their column, cycling by the row's index so a
/// screenful reads as different rows rather than one stamped again — the
/// same cycle on every list, so the app's skeletons share one rhythm.
///
/// Three lines cover every row: a short leading line (a name, a title, a
/// comment's header), the short line under it (a handle, a time), and a long
/// body line (a preview, a comment, a message).
public enum SkeletonLineWidths {
    /// A short leading line: a name, a title, a comment's header.
    public static let title: [CGFloat] = [0.44, 0.34, 0.52, 0.38]
    /// The short line under a name: a handle, a time.
    public static let detail: [CGFloat] = [0.30, 0.38, 0.26, 0.34]
    /// A long body line: a preview, a comment, a message.
    public static let body: [CGFloat] = [0.82, 0.64, 0.90, 0.72]

    /// Row `index`'s fraction in `widths`.
    public static func fraction(_ widths: [CGFloat], at index: Int) -> CGFloat {
        widths[((index % widths.count) + widths.count) % widths.count]
    }
}
