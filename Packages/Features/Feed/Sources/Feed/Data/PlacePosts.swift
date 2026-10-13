import CoreContracts
import CoreModels
import CoreNetworking
import FeedInterface
import Foundation
import PostGrid

/// A page of a place's posts past the map's pins (#643).
struct PlacePostsPage: Equatable, Sendable {
    let posts: [GalleryPost]
    /// Nil on the last page.
    let nextPageToken: String?
}

/// A place's posts, page by page: geo_discovery.v1 `ListPlacePosts`.
public protocol PlacePostsListing: Sendable {
    /// One page of ids, most popular first, and the token of the next (nil:
    /// the last). A page can come back short — or empty — with a token.
    func placePostIDs(_ place: PlaceQuery, after pageToken: String?) async throws -> (ids: [PostID], next: String?)
}

/// `PlacePostsListing` over the edge.
public struct PlacePostsRepository: PlacePostsListing {
    private let geoClient: any GeoDiscovery_V1_GeoDiscoveryServiceClientInterface
    /// Posts per page: the server's most.
    static let pageSize: Int32 = 50

    public init(geoClient: any GeoDiscovery_V1_GeoDiscoveryServiceClientInterface) {
        self.geoClient = geoClient
    }

    public func placePostIDs(_ place: PlaceQuery, after pageToken: String?) async throws -> (ids: [PostID], next: String?) {
        var request = GeoDiscovery_V1_ListPlacePostsRequest()
        switch place {
        case .country(let code):
            request.countryCode = code
        case .city(let latitude, let longitude):
            var point = GeoDiscovery_V1_PlacePoint()
            point.lat = latitude
            point.lng = longitude
            point.scale = .city
            request.point = point
        }
        // The page leads with what the place is known for, as its grid does.
        request.sort = .popular
        request.limit = Self.pageSize
        request.pageToken = pageToken ?? ""
        let response = await geoClient.listPlacePosts(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            // POPULAR reads the ranking again per page: a post can come back.
            var seen = Set<String>()
            let ids = body.cards.map(\.postID).filter { seen.insert($0).inserted }.map { PostID($0) }
            return (ids, body.nextPageToken.isEmpty ? nil : body.nextPageToken)
        case .failure(let error):
            throw FeedError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }
}
