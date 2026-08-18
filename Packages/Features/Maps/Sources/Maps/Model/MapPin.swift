import CoreModels
import Foundation

/// A lightweight map marker — the client projection of `geo_discovery.v1`'s
/// `RadarPin`. Carries only what a marker needs to render during pan/zoom (the
/// high-frequency Radar path); author/caption/engagement are hydrated on tap
/// via the Focus path (`GetGeoTimeline`, Step B).
///
/// Deliberately free of MapKit/CoreLocation so the diffing engine and the
/// viewport math stay pure and unit-testable. `latitude`/`longitude` are raw
/// WGS-84 degrees; the annotation layer wraps them in a `CLLocationCoordinate2D`.
public struct MapPin: Sendable, Equatable, Identifiable {
    /// What the post *is*, which decides the marker's face: a cover image for
    /// the two media kinds, a symbol for `.text`.
    ///
    /// Three cases rather than `MediaCore.MediaKind`'s two, mirroring
    /// `PostGrid.GalleryPost.Kind` — a text post has no media kind, and typing
    /// one as `.image` is what let a text pin render as a blank grey square
    /// while every `mediaKind` check still read as correct.
    public enum Kind: Sendable, Equatable {
        case photo
        case video
        /// A text-only post: no cover to fetch, no preview to play.
        case text
    }

    public var id: PostID { postID }

    public let postID: PostID
    public let latitude: Double
    public let longitude: Double
    /// Pin cover image; `nil` for a `.text` pin (and for a media post the
    /// backend never stamped a thumbnail on — see `kind`).
    public let thumbnailURL: URL?
    /// Photo / video / text discriminator, driving the play badge and the text
    /// face. Until `RadarPin.media_kind` (additive field 5) is published and
    /// regenerated, the repository can only tell text from media — every media
    /// pin reads as `.photo`; see `GeoDiscoveryRepository.kind(for:)`.
    public let kind: Kind
    /// A lightweight looping clip for the live map preview. `nil` today: the
    /// Radar path carries no video URL (only a still `thumbnail_url`), so
    /// production autoplay is blocked on a second additive field
    /// (`RadarPin.preview_video_url`) the backend hasn't scoped yet. The video
    /// pool is fully built behind this and lights up when the URL arrives.
    public let previewVideoURL: URL?
    /// counter.v1's LIKE projection for this post — the popularity signal a
    /// cluster's face competes on (`MapClusterEngine.representative`).
    /// Batch-hydrated by `GeoDiscoveryRepository` after the Radar query (the
    /// Radar wire itself carries no engagement), fail-open: a failed or
    /// missing counter read leaves 0, which only costs the marker its claim
    /// on a group's face.
    public let likeCount: Int64
    /// The NESTED semantic places this post belongs to, most specific first
    /// (city, then its region, then its country) — the hierarchy ladder the
    /// zoom-banded roll-up climbs. Empty for the ordinary pin, and always
    /// empty in production — the wire carries no place identity
    /// (`dev/BACKEND_GAPS.md` §18); populated only by `MapMockPlaces` under
    /// its DEBUG launch argument.
    public let places: [MapPlace]

    /// The most specific place — what a proximity cluster's members must
    /// share to make it SEMANTIC (Case B); everything else is generic.
    public var place: MapPlace? { places.first }

    /// Whether this marker shows a symbol instead of a cover image.
    public var isText: Bool { kind == .text }

    public init(
        postID: PostID,
        latitude: Double,
        longitude: Double,
        thumbnailURL: URL?,
        kind: Kind,
        previewVideoURL: URL? = nil,
        likeCount: Int64 = 0,
        places: [MapPlace] = []
    ) {
        self.postID = postID
        self.latitude = latitude
        self.longitude = longitude
        self.thumbnailURL = thumbnailURL
        self.kind = kind
        self.previewVideoURL = previewVideoURL
        self.likeCount = likeCount
        self.places = places
    }

    /// The same pin, tagged with its place ladder — the decoration seam
    /// `MapMockPlaces` uses (a `let`-field struct has no other way to amend
    /// one field).
    public func tagged(with places: [MapPlace]) -> MapPin {
        MapPin(
            postID: postID,
            latitude: latitude,
            longitude: longitude,
            thumbnailURL: thumbnailURL,
            kind: kind,
            previewVideoURL: previewVideoURL,
            likeCount: likeCount,
            places: places
        )
    }

    /// The same pin carrying its counter projection — the hydration seam
    /// `GeoDiscoveryRepository` amends through, for the same reason as
    /// `tagged(with:)`.
    public func liked(_ likeCount: Int64) -> MapPin {
        MapPin(
            postID: postID,
            latitude: latitude,
            longitude: longitude,
            thumbnailURL: thumbnailURL,
            kind: kind,
            previewVideoURL: previewVideoURL,
            likeCount: likeCount,
            places: places
        )
    }
}
