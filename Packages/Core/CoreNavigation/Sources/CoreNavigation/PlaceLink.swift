import Foundation

/// A place as a link names it (#985): what the server lists its posts by —
/// a country by its code, or the city cell around a point
/// (`geo_discovery.v1.ListPlacePosts`) — and, for a city, the name its page
/// shows, which no service gives for a point.
///
///     https://core-platform.click/place/country/FR
///     https://core-platform.click/place/city/48.8566,2.3522?name=Paris&country=FR
///
/// ⚠️ NOT THE MAP'S `MapPlace.id` ("city:paris"). That identity is the mock's
/// own and means nothing to the server; a link carries what the server can
/// answer, so it opens the same place on any device, in any mode.
public enum PlaceLink: Equatable, Sendable {
    /// ISO 3166-1 alpha-2, uppercased.
    case country(code: String)
    /// The city cell around this point, its name, and its country's code
    /// when known (for the page's flag and subtitle).
    case city(latitude: Double, longitude: Double, name: String, countryCode: String?)

    /// The link's web form, on `AppRoute.webHost`.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = AppRoute.webHost
        switch self {
        case .country(let code):
            components.path = "/place/country/" + code
        case .city(let latitude, let longitude, let name, let countryCode):
            components.path = "/place/city/" + Self.coordinate(latitude) + "," + Self.coordinate(longitude)
            var items = [URLQueryItem(name: "name", value: name)]
            if let countryCode { items.append(URLQueryItem(name: "country", value: countryCode)) }
            components.queryItems = items
        }
        return components.url
    }

    /// Reads a link's path after `place` and its query: nil for anything
    /// malformed — a code that is not two letters, a coordinate out of range,
    /// a city with no name.
    init?(path: [String], query: [URLQueryItem]) {
        guard path.count == 2 else { return nil }
        switch path[0].lowercased() {
        case "country":
            guard let code = Self.countryCode(path[1]) else { return nil }
            self = .country(code: code)
        case "city":
            let numbers = path[1].split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 2, (-90...90).contains(numbers[0]), (-180...180).contains(numbers[1]),
                  let name = query.first(where: { $0.name == "name" })?.value?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  (1...80).contains(name.count)
            else { return nil }
            let country = query.first { $0.name == "country" }?.value.flatMap(Self.countryCode)
            self = .city(latitude: numbers[0], longitude: numbers[1], name: name, countryCode: country)
        default:
            return nil
        }
    }

    private static func countryCode(_ raw: String) -> String? {
        let code = raw.uppercased()
        guard code.count == 2, code.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return code
    }

    /// Four decimals: about 11 m, finer than any city cell.
    private static func coordinate(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
