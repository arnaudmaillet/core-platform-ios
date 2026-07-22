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

    /// The request-header channel the selection travels on (see above).
    public static let headerName = "x-map-filter"
    private static let profileTokenPrefix = "profile:"
    private static let pinnedCategoryTokenPrefix = "pinned:"

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
        }
    }

    public init?(wireToken: String) {
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

    public init(profileID: ProfileID, title: String, avatarURL: URL? = nil) {
        self.profileID = profileID
        self.title = title
        self.avatarURL = avatarURL
    }
}
