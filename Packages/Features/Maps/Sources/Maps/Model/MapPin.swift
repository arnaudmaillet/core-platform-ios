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

    /// The author's avatar, which is what a TEXT marker wears instead of a
    /// glyph — a text post has no cover, and an anonymous symbol says only
    /// "not a photograph" where the product wants "whose".
    ///
    /// ⚠️ ALWAYS `nil` IN PRODUCTION. `RadarPin` carries no author at all
    /// (`dev/issues/BACKEND_MAP_PIN_AUTHOR.md`): the avatar exists on the wire,
    /// but on `MapPostCard`, which only `GetGeoTimeline` returns — the
    /// after-a-tap enrichment whose own contract says the pan path
    /// deliberately avoids it. Populated in DEBUG mock mode by the same
    /// decorator seam `places` uses, so the marker and its fallback are both
    /// built and testable today and the day the field lands only
    /// `GeoDiscoveryRepository` changes.
    public let authorAvatarURL: URL?

    /// A baked animated icon this post carries — the catalogue key, not a URL.
    ///
    /// ONLY a text-only post may have one, on the wire and here: a media post
    /// has a cover, and an icon competing with it would be a second answer to
    /// "what is this". The rule is the backend's
    /// (`dev/issues/BACKEND_ANIMATED_PIN_ICONS.md`, `icon_id` set only when
    /// `thumbnail_url` is empty) and the repository re-checks it rather than
    /// trusting it, because a server that broke the invariant would otherwise
    /// paint icons over photographs.
    ///
    /// It outranks `authorAvatarURL`: an icon is something the AUTHOR CHOSE to
    /// say about this post, where the avatar is who they are, and the more
    /// specific statement wins the marker.
    ///
    /// ⚠️ ALWAYS `nil` IN PRODUCTION today — `RadarPin` has no `icon_id` yet
    /// (proposed as field 12). Populated in DEBUG mock mode through the same
    /// decorator seam `places` and `authorAvatarURL` use.
    ///
    /// A `String` rather than the wire's `uint32` because what the client needs
    /// is the CATALOGUE key; mapping the integer onto it is the repository's
    /// job the day the field lands, and doing it here would put a wire detail
    /// in the view layer's vocabulary.
    public let animatedIconID: String?

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
        places: [MapPlace] = [],
        authorAvatarURL: URL? = nil,
        animatedIconID: String? = nil
    ) {
        self.postID = postID
        self.latitude = latitude
        self.longitude = longitude
        self.thumbnailURL = thumbnailURL
        self.kind = kind
        self.previewVideoURL = previewVideoURL
        self.likeCount = likeCount
        self.places = places
        self.authorAvatarURL = authorAvatarURL
        self.animatedIconID = animatedIconID
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
            places: places,
            authorAvatarURL: authorAvatarURL,
            animatedIconID: animatedIconID
        )
    }

    /// The same pin wearing its author's face — the seam the DEBUG mock
    /// decorator amends through, and the one line `GeoDiscoveryRepository`
    /// will call the day `RadarPin` carries an avatar.
    public func wearing(_ authorAvatarURL: URL?) -> MapPin {
        MapPin(
            postID: postID,
            latitude: latitude,
            longitude: longitude,
            thumbnailURL: thumbnailURL,
            kind: kind,
            previewVideoURL: previewVideoURL,
            likeCount: likeCount,
            places: places,
            authorAvatarURL: authorAvatarURL,
            animatedIconID: animatedIconID
        )
    }

    /// The same pin showing its animated icon — the fourth decoration seam,
    /// for the same reason as `wearing(_:)`: every field is a `let`.
    public func showing(_ animatedIconID: String?) -> MapPin {
        MapPin(
            postID: postID,
            latitude: latitude,
            longitude: longitude,
            thumbnailURL: thumbnailURL,
            kind: kind,
            previewVideoURL: previewVideoURL,
            likeCount: likeCount,
            places: places,
            authorAvatarURL: authorAvatarURL,
            animatedIconID: animatedIconID
        )
    }

    /// Whether this marker wears baked artwork instead of a face.
    ///
    /// Guarded on `isText` as well as on the id, so a server that stamped an
    /// icon onto a media post cannot paint over its cover.
    public var hasAnimatedIcon: Bool { isText && animatedIconID != nil }

    /// The frame this marker starts on — a pure function of identity, so the
    /// hero flight card reproduces the exact frame by copying one `Int` rather
    /// than by sampling the marker mid-animation.
    ///
    /// ⚠️ NOT `hashValue`. Swift seeds its string hash per launch, so the same
    /// post would start on a different frame every run: every screenshot diff
    /// would drift and no QA recipe could pin a field's appearance. FNV-1a is
    /// stable across launches and across devices.
    public var iconPhase: Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in postID.rawValue.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return Int(hash % 997)
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
            places: places,
            authorAvatarURL: authorAvatarURL,
            animatedIconID: animatedIconID
        )
    }
}
