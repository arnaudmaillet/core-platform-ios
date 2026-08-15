import Testing
import MapKit
@testable import Maps

/// The lightweight H3 decoder: index parsing per the public bit layout, the
/// published scale table, and the geometry it derives — the client half of
/// `dev/issues/BACKEND_H3_BOUNDING_BOX.md`.
struct H3CellGeometryTests {
    @Test func aWellFormedIndexRoundTrips() {
        for resolution in [0, 1, 3, 5, 9, 15] {
            let index = H3CellGeometry.makeIndex(resolution: resolution, baseCell: 14)
            let cell = H3CellGeometry(index: index)
            #expect(cell?.resolution == resolution)
            #expect(cell?.baseCell == 14)
        }
    }

    /// Anything that is not a mode-1 cell index is refused: zero (the wire's
    /// "not indexed"), a wrong mode, a set high bit.
    @Test func malformedIndexesAreRefused() {
        #expect(H3CellGeometry(index: 0) == nil)
        let valid = H3CellGeometry.makeIndex(resolution: 5, baseCell: 14)
        #expect(H3CellGeometry(index: valid | (1 << 63)) == nil)
        let wrongMode = (valid & ~(UInt64(0xF) << 59)) | (2 << 59)
        #expect(H3CellGeometry(index: wrongMode) == nil)
    }

    /// The scale ladder: spans strictly shrink as resolution grows — the
    /// property the banding rule rests on.
    @Test func spansShrinkMonotonicallyWithResolution() {
        let spans = (0...15).map {
            H3CellGeometry(index: H3CellGeometry.makeIndex(resolution: $0, baseCell: 14))!
                .averageSpanKm
        }
        #expect(spans == spans.sorted(by: >))
        #expect(zip(spans, spans.dropFirst()).allSatisfy { $0 > $1 })
    }

    /// The mock anchors' real-world scales: Paris-ish at res 5 (~17 km),
    /// Île-de-France-ish at res 3 (~120 km), France-ish at res 1 (~840 km).
    @Test func theMockResolutionsMatchTheirFootprints() {
        func span(_ res: Int) -> Double {
            H3CellGeometry(index: H3CellGeometry.makeIndex(resolution: res, baseCell: 14))!
                .averageSpanKm
        }
        #expect(abs(span(5) - 17.1) < 0.1)
        #expect(abs(span(3) - 119.6) < 0.1)
        #expect(abs(span(1) - 837.4) < 0.1)
    }

    /// Boundary and bounding box: six points ringing the anchor at the edge
    /// length, and a region whose spans express the cell's km span at the
    /// anchor's latitude.
    @Test func geometryIsAnchoredAndScaled() {
        let cell = H3CellGeometry(index: H3CellGeometry.makeIndex(resolution: 5, baseCell: 14))!
        let anchor = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)

        let boundary = cell.boundary(around: anchor)
        #expect(boundary.count == 6)
        for point in boundary {
            let latKm = (point.latitude - anchor.latitude) * 111.0
            let lngKm = (point.longitude - anchor.longitude) * 111.0
                * cos(anchor.latitude * .pi / 180)
            let radius = (latKm * latKm + lngKm * lngKm).squareRoot()
            #expect(abs(radius - cell.averageEdgeKm) < 0.05,
                    "every corner sits one edge length from the anchor")
        }

        let region = cell.region(around: anchor)
        #expect(region.center.latitude == anchor.latitude)
        #expect(abs(region.span.latitudeDelta * 111.0 - cell.averageSpanKm) < 0.01)
        #expect(region.span.longitudeDelta > region.span.latitudeDelta,
                "longitude degrees are shorter at Paris's latitude, so the delta is larger")
    }
}
