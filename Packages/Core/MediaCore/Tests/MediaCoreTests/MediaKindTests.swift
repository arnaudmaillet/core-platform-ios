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
}
