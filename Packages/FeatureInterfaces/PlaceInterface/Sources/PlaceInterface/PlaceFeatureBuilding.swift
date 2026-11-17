import CoreModels
import CoreNavigation
import UIKit

/// Entry point contract for the Place feature (#2381): a place's page, from
/// the map (pins, the feed above it, a way home to the marker) or alone (a
/// shared place link). Maps and the app shell depend on this interface, never
/// on the Place implementation.
@MainActor
public protocol PlaceFeatureBuilding: AnyObject {
    func makeClusterGallery(
        postIDs: [PostID],
        title: String,
        rank: PlaceRankBadge?,
        identity: PlaceIdentity?,
        following: ClusterGalleryFollowing?,
        feed: UIViewController,
        mapReturn: @escaping (@escaping () -> UIImage?) -> (any ZoomTransitionSource)?,
        markerClose: ((UIViewController) -> RevealGeometry?)?
    ) -> UIViewController

    /// A place's page opened ALONE — a shared place link (#985): no map and
    /// no feed under it, no pins handed in. Its posts come page by page from
    /// `identity.query`; a plain push, closed by the back swipe.
    func makePlacePage(title: String, identity: PlaceIdentity) -> UIViewController
}

extension PlaceFeatureBuilding {
    /// A place with no rank and no flag to show.
    public func makeClusterGallery(
        postIDs: [PostID],
        title: String,
        following: ClusterGalleryFollowing?,
        feed: UIViewController,
        mapReturn: @escaping (@escaping () -> UIImage?) -> (any ZoomTransitionSource)?
    ) -> UIViewController {
        makeClusterGallery(
            postIDs: postIDs, title: title, rank: nil, identity: nil, following: following,
            feed: feed, mapReturn: mapReturn, markerClose: nil
        )
    }
}

/// Where a place stands among places of its kind — "#3 City Rank" — shown as
/// the first counter of its page.
///
/// ⚠️ **NO WIRE CARRIES THIS YET.** Mock mode supplies it from the place
/// catalog (`MapMockPlaces`); production passes nil and the column is not
/// drawn.
public struct PlaceRankBadge: Equatable, Sendable {
    /// 1-based.
    public let position: Int
    /// The caption: "City Rank", "Country Rank".
    public let label: String

    public init(position: Int, label: String) {
        self.position = position
        self.label = label
    }

    /// "#3".
    public var positionText: String { "#\(position)" }
}

/// What the place page's identity row wears beside the name: the place's
/// round flag (a city's is its country's) and its subtitle (a country's
/// continent, a city's country). Resolved by the map, which owns the flags
/// and the atlas; nil when the place stands in no country (at sea).
public struct PlaceIdentity {
    public let flag: UIImage?
    public let subtitle: String?
    /// The place's public web address — what its QR code carries. Nil: the
    /// page draws no QR button.
    public let shareURL: URL?
    /// Which place the server lists the posts of (#643) — past the map's
    /// pins, page by page. Nil: the page shows the pins it was handed.
    public let query: PlaceQuery?
    /// The place pinned to the map's dock (#1598): its state and its toggle,
    /// bound by the map to its own store. Nil: the page offers no pin.
    public let dockPin: ClusterGalleryFollowing?

    public init(
        flag: UIImage?, subtitle: String?, shareURL: URL? = nil, query: PlaceQuery? = nil,
        dockPin: ClusterGalleryFollowing? = nil
    ) {
        self.flag = flag
        self.subtitle = subtitle
        self.shareURL = shareURL
        self.query = query
        self.dockPin = dockPin
    }
}

/// A place as geo_discovery.v1 `ListPlacePosts` names one (#643): a country
/// by its ISO code, a city by the point at its centre.
public enum PlaceQuery: Equatable, Sendable {
    /// ISO 3166-1 alpha-2.
    case country(String)
    /// The city cell around this point.
    case city(latitude: Double, longitude: Double)
}

/// The follow-this-place seam a cluster gallery's header renders: the caller
/// (Maps, whose store owns the followed set) hands the gallery the state and
/// the toggle, and the gallery is just a button. Closures rather than a
/// protocol on purpose — the gallery must not know what a place IS, only
/// whether its subject is followed and how to flip that.
public struct ClusterGalleryFollowing {
    /// The current state, read fresh whenever the button renders.
    public let isFollowing: @MainActor () -> Bool
    /// Flips the state, returning the NEW value — what the button shows next.
    public let toggle: @MainActor () -> Bool

    public init(
        isFollowing: @escaping @MainActor () -> Bool,
        toggle: @escaping @MainActor () -> Bool
    ) {
        self.isFollowing = isFollowing
        self.toggle = toggle
    }
}
