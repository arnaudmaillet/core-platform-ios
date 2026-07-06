import CoreGraphics

/// Spacing scale. All layout code uses these tokens instead of magic numbers
/// so density changes are a one-line edit.
public enum Spacing {
    /// 4pt
    public static let xs: CGFloat = 4
    /// 8pt
    public static let sm: CGFloat = 8
    /// 12pt
    public static let md: CGFloat = 12
    /// 16pt
    public static let lg: CGFloat = 16
    /// 24pt
    public static let xl: CGFloat = 24
    /// 32pt
    public static let xxl: CGFloat = 32
}
