import Foundation

/// How a media attachment should be presented. Derived from the attachment's
/// MIME type so the domain model needs no new stored field: a `video/*` type
/// renders through the player subsystem, everything else through the image
/// pipeline.
///
/// The backend has no video media kind yet (`media.v1.MediaKind` is image-only,
/// with video a planned additive enum), so today only mock `video/*` posts take
/// the video path — but the client seam is real and ready.
public enum MediaKind: Sendable, Equatable {
    case image
    case video

    /// HLS manifests are video but do not carry a `video/` MIME type. Both
    /// spellings are in the wild and must be matched case-insensitively:
    /// `application/vnd.apple.mpegurl` is the registered type, while Apple's
    /// own devstreaming CDN serves the legacy `application/x-mpegURL`.
    ///
    /// Missing these was a real gap: an HLS attachment classified as `.image`
    /// never reaches the player, so it renders as a broken still. The video
    /// pipeline requirements in `dev/PHASE3_VIDEO_BACKEND.md` §0 already
    /// specified this routing before the code implemented it.
    private static let hlsMIMETypes: Set<String> = [
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl"
    ]

    public init(mimeType: String) {
        let normalized = mimeType.lowercased()
        self = normalized.hasPrefix("video/") || Self.hlsMIMETypes.contains(normalized) ? .video : .image
    }
}
