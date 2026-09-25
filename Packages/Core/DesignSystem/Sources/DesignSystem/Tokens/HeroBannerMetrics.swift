import CoreGraphics

/// The geometry a picture-led header shares across screens.
///
/// ⚠️ **ONE NUMBER, TWO SCREENS, SO THEY CANNOT DRIFT APART.** A profile's
/// POSTER banner and a place's banner are the same design — a picture stage
/// under the navigation chrome, the identity at its foot, the counters under
/// it — and were built separately: the place's banner was 70% of the screen
/// while the profile's poster gave its picture 200pt, and the two read as
/// different products ("la bannière est beaucoup trop haute", 25 September
/// 2026). Both read the stage from here now.
public enum HeroBannerMetrics {
    /// The raw picture between the navigation chrome's bottom edge and the
    /// identity block that stands on the banner.
    public static let posterStage: CGFloat = 200
    /// The identity column's side margins — the profile header's, which is
    /// wider than the standard page margin so the block reads airy against a
    /// full-bleed picture.
    public static let identityInset: CGFloat = 20
}
