import CoreLocation
import Foundation

/// The world's countries as the map draws and unlocks them: borders, names,
/// label points.
///
/// Read from `Resources/countries.json`, imported from Natural Earth 1:50m
/// "Admin 0 – Countries" (public domain) by `Scripts/import-country-borders.py`
/// — simplified to country scale, 237 entries keyed by ISO 3166-1 alpha-2.
///
/// ⚠️ **LOADED ONCE, OFF THE MAIN THREAD WHEN IT CAN BE.** ~0.9 MB of JSON and
/// 52k points is a few tens of milliseconds to decode; `shared` is lazy and
/// thread-safe, and the map warms it on a background queue before it asks.
public final class CountryAtlas: Sendable {
    public struct Country: Sendable, Identifiable, Equatable {
        /// ISO 3166-1 alpha-2, uppercased ("FR").
        public let code: String
        public let name: String
        public let continent: String
        public let population: Int
        /// Where to write the country's name: inside it, even for a crescent
        /// or an archipelago (Natural Earth's own label point, not a centroid).
        public let label: CLLocationCoordinate2D
        /// Polygons, each an outer ring followed by its holes, in
        /// (latitude, longitude) points.
        public let polygons: [[[CLLocationCoordinate2D]]]
        /// Longitude/latitude bounds, for a cheap first test.
        public let bounds: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)

        public var id: String { code }

        /// The regional-indicator flag ("🇫🇷").
        public var flag: String {
            code.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
                .map(String.init).joined()
        }

        public static func == (lhs: Country, rhs: Country) -> Bool { lhs.code == rhs.code }

        /// Whether `coordinate` falls inside the country — even-odd over every
        /// ring, so a hole (a lake, an enclave) is outside.
        public func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
            let x = coordinate.longitude, y = coordinate.latitude
            guard x >= bounds.minLon, x <= bounds.maxLon, y >= bounds.minLat, y <= bounds.maxLat else {
                return false
            }
            for polygon in polygons {
                var inside = false
                for ring in polygon where Self.ring(ring, contains: x, y) { inside.toggle() }
                if inside { return true }
            }
            return false
        }

        /// The bounds of the piece the label stands in: the mainland, without
        /// the overseas territories — France without Guiana and Réunion, which
        /// would frame half the planet. Falls back to the widest piece.
        public var mainlandBounds: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
            let outlines = polygons.compactMap(\.first)
            let box = { (ring: [CLLocationCoordinate2D]) in
                (minLon: ring.map(\.longitude).min() ?? 0, minLat: ring.map(\.latitude).min() ?? 0,
                 maxLon: ring.map(\.longitude).max() ?? 0, maxLat: ring.map(\.latitude).max() ?? 0)
            }
            let home = outlines.first { Self.ring($0, contains: label.longitude, label.latitude) }
                ?? outlines.max { lhs, rhs in
                    let (a, b) = (box(lhs), box(rhs))
                    return (a.maxLon - a.minLon) * (a.maxLat - a.minLat) < (b.maxLon - b.minLon) * (b.maxLat - b.minLat)
                }
            return home.map(box) ?? bounds
        }

        /// How far `coordinate` is from the country's outline, in degrees of
        /// latitude (longitude scaled by the latitude's cosine), or nil when
        /// it is farther than `limit` from the bounds.
        func distance(to coordinate: CLLocationCoordinate2D, within limit: Double) -> Double? {
            let x = coordinate.longitude, y = coordinate.latitude
            let scale = cos(y * .pi / 180)
            guard y >= bounds.minLat - limit, y <= bounds.maxLat + limit,
                  (x - bounds.maxLon) * scale <= limit, (bounds.minLon - x) * scale <= limit else { return nil }
            var best = Double.infinity
            for polygon in polygons {
                guard let ring = polygon.first, ring.count > 1 else { continue }
                var previous = ring[ring.count - 1]
                for point in ring {
                    let (ax, ay) = ((previous.longitude - x) * scale, previous.latitude - y)
                    let (bx, by) = ((point.longitude - x) * scale, point.latitude - y)
                    let (dx, dy) = (bx - ax, by - ay)
                    let length = dx * dx + dy * dy
                    let t = length == 0 ? 0 : min(1, max(0, -(ax * dx + ay * dy) / length))
                    let (px, py) = (ax + t * dx, ay + t * dy)
                    best = min(best, px * px + py * py)
                    previous = point
                }
            }
            return best.squareRoot()
        }

        private static func ring(_ ring: [CLLocationCoordinate2D], contains x: Double, _ y: Double) -> Bool {
            var inside = false
            var j = ring.count - 1
            for i in 0..<ring.count {
                let (xi, yi) = (ring[i].longitude, ring[i].latitude)
                let (xj, yj) = (ring[j].longitude, ring[j].latitude)
                if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
    }

    public static let shared = CountryAtlas(bundle: .module)

    public let countries: [Country]
    private let byCode: [String: Country]

    init(bundle: Bundle) {
        let countries = Self.load(from: bundle.url(forResource: "countries", withExtension: "json"))
        self.countries = countries
        self.byCode = Dictionary(uniqueKeysWithValues: countries.map { ($0.code, $0) })
    }

    /// The country `code` names.
    public func country(code: String) -> Country? {
        byCode[code.uppercased()]
    }

    /// The country `coordinate` is in; nil at sea.
    public func country(containing coordinate: CLLocationCoordinate2D) -> Country? {
        countries.first { $0.contains(coordinate) }
    }

    /// The country a POST at `coordinate` belongs to: the one it is in, or,
    /// offshore, the one whose coast is nearest within `reach` degrees (~30 km).
    /// Nil only on the open sea.
    ///
    /// ⚠️ **A HARBOUR IS NOT THE HIGH SEAS.** The outlines are simplified to
    /// ~2 km, so a beach, a pier or a boat off Barcelona falls "at sea", and a
    /// post at sea is shown whatever is unlocked: Spain's posts leaked onto a
    /// map where Spain was locked.
    public func country(owning coordinate: CLLocationCoordinate2D, reach: Double = 0.3) -> Country? {
        if let country = country(containing: coordinate) { return country }
        return countries
            .compactMap { country in country.distance(to: coordinate, within: reach).map { (country, $0) } }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }

    private struct Record: Decodable {
        let code: String
        let name: String
        let continent: String?
        let population: Int?
        let label: [Double]
        let polygons: [[[[Double]]]]
    }

    private static func load(from url: URL?) -> [Country] {
        guard let url, let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return records.map { record in
            var minLon = 180.0, minLat = 90.0, maxLon = -180.0, maxLat = -90.0
            let polygons = record.polygons.map { polygon in
                polygon.map { ring in
                    ring.map { point -> CLLocationCoordinate2D in
                        minLon = min(minLon, point[0]); maxLon = max(maxLon, point[0])
                        minLat = min(minLat, point[1]); maxLat = max(maxLat, point[1])
                        return CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
                    }
                }
            }
            return Country(
                code: record.code,
                name: record.name,
                continent: record.continent ?? "",
                population: record.population ?? 0,
                label: CLLocationCoordinate2D(latitude: record.label[1], longitude: record.label[0]),
                polygons: polygons,
                bounds: (minLon, minLat, maxLon, maxLat)
            )
        }
    }
}
