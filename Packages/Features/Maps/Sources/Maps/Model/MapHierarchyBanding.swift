import Foundation

/// Which hierarchy depth renders, decided DYNAMICALLY from geometry: each
/// level's H3 cell span (km) against the camera viewport's diagonal (km) —
/// no fixed zoom table when the corpus carries H3 indexes
/// (`dev/issues/BACKEND_H3_BOUNDING_BOX.md`). The strict-banding contract is
/// unchanged: exactly one level renders at a time.
///
/// The rule, deepest-first over the levels present in the corpus:
/// 1. If the DEEPEST level's `span / diagonal > localRatio`, the viewer is
///    inside that cell — the LOCAL band: individual posts and generic
///    proximity clusters.
/// 2. Otherwise the deepest level whose `span / diagonal ≥ fitRatio` — the
///    level that still dominates the view.
/// 3. Otherwise (zoomed out past everything) the coarsest level present:
///    a hierarchical map never goes blank outward.
///
/// Fixed zoom thresholds survive only as the FALLBACK for a laddered corpus
/// with no H3 anywhere (`fallbackKind`).
enum MapHierarchyBanding {
    /// A level "fits" the view while its cell spans at least this fraction
    /// of the viewport diagonal. Mirrored by the server's resolution rule.
    ///
    /// ⚠️ Calibrated against MEASURED viewport diagonals (`-maps-banding-log`
    /// prints them), not against back-of-envelope span math — MapKit's
    /// fitted region is tighter than the naive aspect blow-up suggests. The
    /// four QA anchors and their city-span (17.1 km) ratios:
    /// default ≈ 12.9 km → city 1.33 · wide ≈ 77 km → region 1.55 ·
    /// country ≈ 205 km → region 0.58 (must NOT fit) / country 4.1 ·
    /// tight ≈ 6.4 km → city 2.67 (must read as inside).
    static let fitRatio = 0.75
    /// Past this the viewer is INSIDE the deepest cell and the hierarchy
    /// stands down — 1.6 puts the default view (1.33) safely in the city
    /// band and the tight view (2.67) safely local.
    static let localRatio = 1.6

    /// Depth order, most specific first.
    private static let depthFirst: [MapPlace.Kind] = [.city, .region, .country]

    /// The active depth — `nil` is the LOCAL band. `spansByKind` holds each
    /// level's H3-derived span (km) where the corpus has one; when it is
    /// empty (no H3 anywhere), `zoomLevel` decides via `fallbackKind`.
    static func activeKind(
        viewportDiagonalKm: Double?,
        spansByKind: [MapPlace.Kind: Double],
        zoomLevel: Int32?
    ) -> MapPlace.Kind? {
        if let diagonal = viewportDiagonalKm, diagonal > 0, !spansByKind.isEmpty {
            if let deepest = depthFirst.first(where: { spansByKind[$0] != nil }),
               let span = spansByKind[deepest], span / diagonal > localRatio {
                return nil
            }
            for kind in depthFirst {
                if let span = spansByKind[kind], span / diagonal >= fitRatio {
                    return kind
                }
            }
            return depthFirst.reversed().first { spansByKind[$0] != nil }
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
