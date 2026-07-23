import CoreModels
import Foundation

/// The map's post filters. Static buckets (relationship/pinned/nearby) plus
/// per-profile favorites — `nil` in the selection APIs means "All".
///
/// Phase-1 contract note: `geo_discovery.v1.QueryTileRequest` has no filter
/// field on the wire, and the backend's documented design (`MapPostCard` doc)
/// is client-side relationship filtering against a session-cached social
/// graph — but `RadarPin` carries no `author_id` yet and no such cache exists.
/// Until one of those lands, the selection travels as the `x-map-filter`
/// request header: the fleet edge ignores unknown headers (pins stay
/// unfiltered there), while the mock BFF honors it so the feature is fully
/// exercisable offline. `wireToken` is the wire encoding —
/// `MockGeoDiscoveryService` matches these strings literally (it cannot
/// import this package).
public enum MapFilter: Hashable, Sendable {
    case friends
    case following
    case pinned
    case nearby
    /// One profile's posts (a favorite pill, or a person sub-filter under
    /// Friends/Following — a person's posts are already a subset of either).
    case profile(ProfileID)
    /// Pinned places narrowed to one category (the Places sub-filter row).
    case pinnedCategory(String)
    /// Several refinements at once — the sub-filter row's multi-selection.
    /// Semantics are OR: a pin matching ANY member is shown ("Lena AND
    /// Marcus" in the viewer's words is "Lena's posts ∪ Marcus's posts").
    /// Members are always leaf cases; `resolved(_:)` is the only builder, and
    /// it flattens and orders them so one selection has exactly one token.
    case any([MapFilter])

    /// The request-header channel the selection travels on (see above).
    public static let headerName = "x-map-filter"
    private static let profileTokenPrefix = "profile:"
    private static let pinnedCategoryTokenPrefix = "pinned:"
    /// Separates the members of an `any` token. The mock splits on it and
    /// matches any component.
    private static let anySeparator = ","

    /// Collapses a set of filters into one: nothing, the lone member, or an
    /// `any` in a stable order (sets are unordered — the header must not
    /// churn between two identical selections).
    public static func resolved(_ filters: [MapFilter]) -> MapFilter? {
        let leaves = filters.flatMap { filter -> [MapFilter] in
            if case .any(let members) = filter { return members }
            return [filter]
        }
        let unique = Array(Set(leaves)).sorted { $0.wireToken < $1.wireToken }
        switch unique.count {
        case 0: return nil
        case 1: return unique[0]
        default: return .any(unique)
        }
    }

    /// The wire encoding sent in `headerName` (and accepted by the
    /// `-maps-select-filter` debug arg).
    public var wireToken: String {
        switch self {
        case .friends: "friends"
        case .following: "following"
        case .pinned: "pinned"
        case .nearby: "nearby"
        case .profile(let id): Self.profileTokenPrefix + id.rawValue
        case .pinnedCategory(let category): Self.pinnedCategoryTokenPrefix + category
        case .any(let members): members.map(\.wireToken).joined(separator: Self.anySeparator)
        }
    }

    public init?(wireToken: String) {
        // A multi-selection token is the leaf tokens joined; parse it back
        // through `resolved` so the round trip is exact.
        if wireToken.contains(Self.anySeparator) {
            let members = wireToken.split(separator: Self.anySeparator)
                .compactMap { MapFilter(wireToken: String($0)) }
            guard let resolved = Self.resolved(members) else { return nil }
            self = resolved
            return
        }
        switch wireToken {
        case "friends": self = .friends
        case "following": self = .following
        case "pinned": self = .pinned
        case "nearby": self = .nearby
        default:
            if wireToken.hasPrefix(Self.profileTokenPrefix) {
                let id = String(wireToken.dropFirst(Self.profileTokenPrefix.count))
                guard !id.isEmpty else { return nil }
                self = .profile(ProfileID(id))
            } else if wireToken.hasPrefix(Self.pinnedCategoryTokenPrefix) {
                let category = String(wireToken.dropFirst(Self.pinnedCategoryTokenPrefix.count))
                guard !category.isEmpty else { return nil }
                self = .pinnedCategory(category)
            } else {
                return nil
            }
        }
    }
}

/// A refinement of the active primary filter, shown in the sub-filter bar
/// above the main one: a person under Friends/Following, or a place category
/// under Places. `nil` in the selection APIs means "no refinement".
///
/// A sub-filter never travels on the wire by itself — `MapsViewModel`
/// resolves (primary, sub) into one effective `MapFilter` (`.profile` /
/// `.pinnedCategory`) before querying.
public enum MapSubFilter: Hashable, Sendable {
    case profile(ProfileID)
    case placeCategory(String)
}

/// One person in the filter bars: a favorite pill in the main bar, or a
/// friend/following entry in the sub-filter row. No dedicated "favorites"
/// contract exists — the pinned set is client-persisted (`MapFavoritesStore`)
/// and hydrated from the social graph.
public struct MapFavorite: Sendable, Equatable {
    public let profileID: ProfileID
    /// Pill label — display name, falling back to @handle upstream.
    public let title: String
    /// Avatar thumbnail, rendered in people pills and the full-list sheet.
    public let avatarURL: URL?
    /// Raw handle, no "@" sigil — the consumer applies presentation (the
    /// sheet's subtitle line, the profile route's identity stub). Optional:
    /// a profile that failed to hydrate a handle still makes a valid pill.
    public let handle: String?

    public init(profileID: ProfileID, title: String, avatarURL: URL? = nil, handle: String? = nil) {
        self.profileID = profileID
        self.title = title
        self.avatarURL = avatarURL
        self.handle = handle
    }
}
