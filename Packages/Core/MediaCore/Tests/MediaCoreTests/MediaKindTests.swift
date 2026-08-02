import Foundation
import Testing
@testable import MediaCore

struct MediaKindTests {
    @Test func videoMimeTypesMapToVideo() {
        #expect(MediaKind(mimeType: "video/mp4") == .video)
        #expect(MediaKind(mimeType: "VIDEO/QUICKTIME") == .video)
    }

    @Test func nonVideoMimeTypesMapToImage() {
        #expect(MediaKind(mimeType: "image/png") == .image)
        #expect(MediaKind(mimeType: "image/jpeg") == .image)
        #expect(MediaKind(mimeType: "") == .image)
    }

    /// HLS manifests are video without a `video/` prefix. Both spellings occur:
    /// the registered `application/vnd.apple.mpegurl`, and the legacy
    /// `application/x-mpegURL` that Apple's own devstreaming CDN actually
    /// serves — mixed case included. Classifying either as `.image` sends an
    /// HLS post to the image pipeline, where it renders as a broken still.
    @Test func hlsManifestMimeTypesMapToVideo() {
        #expect(MediaKind(mimeType: "application/vnd.apple.mpegurl") == .video)
        #expect(MediaKind(mimeType: "application/x-mpegURL") == .video)
        #expect(MediaKind(mimeType: "APPLICATION/VND.APPLE.MPEGURL") == .video)
    }

    /// Neighbouring `application/*` types must not be swept in.
    @Test func otherApplicationMimeTypesStayImage() {
        #expect(MediaKind(mimeType: "application/json") == .image)
        #expect(MediaKind(mimeType: "application/octet-stream") == .image)
    }
}
