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
