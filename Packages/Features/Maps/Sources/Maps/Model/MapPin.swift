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

    /// Whether this marker shows a symbol instead of a cover image.
    public var isText: Bool { kind == .text }

    public init(
        postID: PostID,
        latitude: Double,
        longitude: Double,
        thumbnailURL: URL?,
        kind: Kind,
        previewVideoURL: URL? = nil
    ) {
        self.postID = postID
        self.latitude = latitude
        self.longitude = longitude
        self.thumbnailURL = thumbnailURL
        self.kind = kind
        self.previewVideoURL = previewVideoURL
    }
}
