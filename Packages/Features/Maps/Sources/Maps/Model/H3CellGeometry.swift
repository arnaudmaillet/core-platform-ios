import Foundation
import MapKit

/// Lightweight decoder for H3 cell indexes — the client half of the aligned
/// hierarchy contract (`dev/issues/BACKEND_H3_BOUNDING_BOX.md`): a cluster's
/// `h3_index` deterministically defines its geographic cell, and this type
/// turns that index into the numbers the map needs — the cell's RESOLUTION,
/// its average SPAN in km, and boundary/bounding-box geometry around the
/// anchor coordinate the pin or cluster already carries.
///
/// ⚠️ Deliberately NOT the full H3 kernel. The public 64-bit index layout
/// (mode, resolution, base cell, digits) is parsed exactly per the H3 spec,
/// and the per-resolution average edge lengths are H3's published constants —
/// but the exact cell-to-boundary math (icosahedral gnomonic projection) is
/// out of scope: banding and camera fits need the cell's SCALE, not its
/// survey-accurate outline, and the wire shape doesn't change if the real
/// kernel is vendored later. The boundary this returns is the regular
/// hexagon of the cell's average edge length centred on the caller's anchor.
struct H3CellGeometry: Equatable {
    /// The raw mode-1 (cell) index.
    let index: UInt64
    /// Resolution 0–15, parsed from bits 52–55.
    let resolution: Int

    /// Parses `index`, refusing anything that is not a well-formed cell
    /// index: the high bit must be 0 and the mode field (bits 59–62) must
    /// be 1. `0` — the wire's "not indexed" — is refused here too (mode 0).
    init?(index: UInt64) {
        guard index >> 63 == 0, (index >> 59) & 0xF == 1 else { return nil }
        self.index = index
        self.resolution = Int((index >> 52) & 0xF)
    }

    /// Base cell 0–121, bits 45–51 — parsed for validity/debugging; the
    /// scale math never needs it.
    var baseCell: Int { Int((index >> 45) & 0x7F) }

    /// H3's published AVERAGE hex edge lengths per resolution, in km.
    static let averageEdgeKm: [Double] = [
        1107.712591, 418.6760055, 158.2446558, 59.81085794, 22.6063794,
        8.544408276, 3.229482772, 1.220629759, 0.461354684, 0.174375668,
        0.065907807, 0.024910561, 0.009415526, 0.003559893, 0.001348575,
        0.000509713,
    ]

    var averageEdgeKm: Double { Self.averageEdgeKm[resolution] }

    /// The cell's characteristic span — the hexagon's long diagonal
    /// (2 × edge, since a regular hexagon's circumradius IS its edge
    /// length). What the banding rule compares against the viewport.
    var averageSpanKm: Double { averageEdgeKm * 2 }

    /// The cell's hexagonal boundary around `center` — six points at the
    /// average edge length. Flat-top orientation; see the type note for why
    /// this is an average-scale hexagon rather than the true cell outline.
    func boundary(around center: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let radiusKm = averageEdgeKm
        return (0..<6).map { corner in
            let angle = Double(corner) * .pi / 3
            return Self.coordinate(
                offsetFrom: center,
                northKm: radiusKm * sin(angle),
                eastKm: radiusKm * cos(angle)
            )
        }
    }

    /// The cell's bounding box around `center`, as the region a camera fit
    /// or a banding comparison consumes.
    func region(around center: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: averageSpanKm / Self.kmPerDegreeLatitude,
                longitudeDelta: averageSpanKm
                    / (Self.kmPerDegreeLatitude * max(0.01, cos(center.latitude * .pi / 180)))
            )
        )
    }

    private static let kmPerDegreeLatitude = 111.0

    private static func coordinate(
        offsetFrom center: CLLocationCoordinate2D, northKm: Double, eastKm: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: center.latitude + northKm / kmPerDegreeLatitude,
            longitude: center.longitude
                + eastKm / (kmPerDegreeLatitude * max(0.01, cos(center.latitude * .pi / 180)))
        )
    }

    /// Constructs a well-formed mode-1 index — the MOCK and the tests'
    /// generator (production indexes come from the wire). Digits beyond
    /// `resolution` are 7 (unused), digits within it 0 (center child),
    /// exactly per the spec's layout: digit N occupies bits 45−3N…47−3N.
    static func makeIndex(resolution: Int, baseCell: Int) -> UInt64 {
        precondition((0...15).contains(resolution) && (0...121).contains(baseCell))
        var index: UInt64 = 1 << 59 // mode = cell
        index |= UInt64(resolution) << 52
        index |= UInt64(baseCell) << 45
        for digit in 1...15 {
            let value: UInt64 = digit <= resolution ? 0 : 7
            index |= value << UInt64(45 - 3 * digit)
        }
        return index
    }
}
