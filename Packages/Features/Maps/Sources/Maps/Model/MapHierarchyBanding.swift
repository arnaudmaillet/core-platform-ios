import Foundation

/// Which hierarchy depth renders, decided DYNAMICALLY from geometry: each
/// level's H3 cell span (km) against the camera viewport's diagonal (km) —
/// no fixed zoom table when the corpus carries H3 indexes
/// (`dev/issues/BACKEND_H3_BOUNDING_BOX.md`). The strict-banding contract is
/// unchanged: exactly one level renders at a time.
///
/// The rule: a level DISSOLVES into its children as soon as the viewport has
/// closed to within `dissolveSpanMultiple ×` that level's own cell span — the
/// moment a boundary fits (or nearly fits) the screen, its single marker
/// stops being informative and the next depth takes over. The active band is
/// the COARSEST level present that has not yet dissolved; when even the
/// deepest level has dissolved the hierarchy stands down entirely — the
/// LOCAL band: individual posts and generic proximity clusters. Zoomed out
/// past everything, nothing has dissolved and the coarsest level renders:
/// a hierarchical map never goes blank outward.
///
/// Fixed zoom thresholds survive only as the FALLBACK for a laddered corpus
/// with no H3 anywhere (`fallbackKind`).
enum MapHierarchyBanding {
    /// A level survives while the viewport diagonal exceeds this multiple of
    /// its cell span; at or below it, the level dissolves. Mirrored by the
    /// server's resolution rule.
    ///
    /// ⚠️ Calibrated against MEASURED viewport diagonals (`-maps-banding-log`
    /// prints them), not against back-of-envelope span math — MapKit fits a
    /// requested region to the portrait aspect, so the measured diagonal can
    /// double a wide target's geographic diagonal. The four framings and the
    /// window they leave, against the mock spans (city 17.1 / region 119.6 /
    /// country 837.4 km): Europe framed = 2884 km must keep country
    /// (multiple < 3.44) · France framed = 1399 km must dissolve it
    /// (≥ 1.67) · Île-de-France framed = 229 km must dissolve region
    /// (≥ 1.91) · Paris framed = 36 km must dissolve city (≥ 2.09).
    /// 2.7 sits mid-window: thresholds country 2261 / region 323 / city 46 km.
    static let dissolveSpanMultiple = 2.7

    /// Coarse-to-deep walk order: the first level that still commands a view
    /// wider than its own cell is the one that renders.
    private static let coarsestFirst: [MapPlace.Kind] = [.country, .region, .city]

    /// The active depth — `nil` is the LOCAL band. `spansByKind` holds each
    /// level's H3-derived span (km) where the corpus has one; when it is
    /// empty (no H3 anywhere), `zoomLevel` decides via `fallbackKind`.
    static func activeKind(
        viewportDiagonalKm: Double?,
        spansByKind: [MapPlace.Kind: Double],
        zoomLevel: Int32?
    ) -> MapPlace.Kind? {
        if let diagonal = viewportDiagonalKm, diagonal > 0, !spansByKind.isEmpty {
            for kind in coarsestFirst {
                if let span = spansByKind[kind], diagonal > span * dissolveSpanMultiple {
                    return kind
                }
            }
            return nil
        }
        guard let zoomLevel else { return nil }
        return fallbackKind(atZoomLevel: zoomLevel)
    }

    /// The zoom-threshold fallback for an H3-less laddered corpus:
    /// country ≤ 5, region 6–8, city 9–11, local 12+.
    static func fallbackKind(atZoomLevel zoomLevel: Int32) -> MapPlace.Kind? {
        switch zoomLevel {
        case ..<6: .country
        case 6...8: .region
        case 9...11: .city
        default: nil
        }
    }
}
