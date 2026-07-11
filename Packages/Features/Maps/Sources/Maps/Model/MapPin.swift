import CoreModels
import Foundation
import MediaCore

/// A lightweight map marker — the client projection of `geo_discovery.v1`'s
/// `RadarPin`. Carries only what a marker needs to render during pan/zoom (the
/// high-frequency Radar path); author/caption/engagement are hydrated on tap
/// via the Focus path (`GetGeoTimeline`, Step B).
///
/// Deliberately free of MapKit/CoreLocation so the diffing engine and the
/// viewport math stay pure and unit-testable. `latitude`/`longitude` are raw
/// WGS-84 degrees; the annotation layer wraps them in a `CLLocationCoordinate2D`.
public struct MapPin: Sendable, Equatable, Identifiable {
    public var id: PostID { postID }

    public let postID: PostID
    public let latitude: Double
    public let longitude: Double
    /// Pin cover image; `nil` for text-only posts (never indexed on the map).
    public let thumbnailURL: URL?
    /// Photo-vs-video discriminator that drives the play badge. Until
    /// `RadarPin.media_kind` (additive field 5) is published and regenerated, the
    /// repository maps every pin to `.image`; see
    /// `GeoDiscoveryRepository.mediaKind(for:)`.
    public let mediaKind: MediaKind
    /// A lightweight looping clip for the live map preview. `nil` today: the
    /// Radar path carries no video URL (only a still `thumbnail_url`), so
    /// production autoplay is blocked on a second additive field
    /// (`RadarPin.preview_video_url`) the backend hasn't scoped yet. The video
    /// pool is fully built behind this and lights up when the URL arrives.
    public let previewVideoURL: URL?

    public init(
        postID: PostID,
        latitude: Double,
        longitude: Double,
        thumbnailURL: URL?,
        mediaKind: MediaKind,
        previewVideoURL: URL? = nil
    ) {
        self.postID = postID
        self.latitude = latitude
        self.longitude = longitude
        self.thumbnailURL = thumbnailURL
        self.mediaKind = mediaKind
        self.previewVideoURL = previewVideoURL
    }
}
