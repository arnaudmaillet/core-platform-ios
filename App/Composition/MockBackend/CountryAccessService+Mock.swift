#if MOCK_BACKEND
import CoreLocation
import CoreNetworkingMocks
import Foundation
import Maps

/// Mock mode's country standings and covers, from the mock corpus (#1075):
/// the app's glue, since the mock backend is the app's to hold. The service
/// itself is Maps' (#2385).
extension CountryAccessService {
    /// Each country's most liked post, as its Shop card's cover (#1075) — what
    /// backend #942's `CountryStanding.cover` will carry.
    static func mockCovers(in backend: MockBackend) -> [String: CountryCover] {
        var best: [String: (postID: String, likes: Int64)] = [:]
        for placement in backend.geoDiscovery.placements() {
            let coordinate = CLLocationCoordinate2D(latitude: placement.latitude, longitude: placement.longitude)
            guard let code = CountryAtlas.shared.country(owning: coordinate)?.code else { continue }
            let likes = backend.counterStore.likeCount(for: placement.postID)
            if let current = best[code], current.likes >= likes { continue }
            best[code] = (placement.postID, likes)
        }
        let posts = Dictionary(backend.dataset.posts.map { ($0.postID, $0) }, uniquingKeysWith: { first, _ in first })
        return best.compactMapValues { top -> CountryCover? in
            guard let post = posts[top.postID] else { return nil }
            guard let media = post.media else {
                return .text(postID: post.postID, caption: post.caption)
            }
            let poster = URL(string: MockGeoDiscoveryService.pinURL(
                forMediaURL: media.url, catalog: backend.dataset.mediaCatalog
            ))
            if MockMediaFixtures.isVideoURL(media.url), let preview = URL(string: media.url) {
                return .video(postID: post.postID, poster: poster, preview: preview)
            }
            return poster.map { .image(postID: post.postID, poster: $0) }
        }
    }

    /// The mock corpus's likes and posts per country: where each post stands,
    /// and the likes it holds.
    static func mockActivity(in backend: MockBackend) -> [String: (likes: Int64, posts: Int)] {
        var activity: [String: (likes: Int64, posts: Int)] = [:]
        for placement in backend.geoDiscovery.placements() {
            let coordinate = CLLocationCoordinate2D(latitude: placement.latitude, longitude: placement.longitude)
            guard let code = CountryAtlas.shared.country(owning: coordinate)?.code else { continue }
            let likes = backend.counterStore.likeCount(for: placement.postID)
            let current = activity[code] ?? (0, 0)
            activity[code] = (current.likes + likes, current.posts + 1)
        }
        return activity
    }
}
#endif
