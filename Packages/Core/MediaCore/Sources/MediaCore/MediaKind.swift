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

    public init(mimeType: String) {
        self = mimeType.lowercased().hasPrefix("video/") ? .video : .image
    }
}
