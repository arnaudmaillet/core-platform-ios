import CoreModels
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// ⚠️ ACTIVATING A FEED HOST'S PAGE NEVER ENDS A FLIGHT'S HANDOFF (#1292).
///
/// A grab runs the host's `viewWillAppear` at its BEGIN, and For You calls
/// `page.setAutoplayActive(true)` there. Since #1278 that one-argument call
/// resolved to the profile's `PostGridPage` witness, which ends the round
/// trip: the tile's return clip was released and its producer stopped,
/// taking the page's joined surface with it — on a device the window flew
/// the still, and a paged close lost the origin tile's clip until it landed.
/// The profile's rule lives under its own name (`setPageActive`).
@MainActor
struct GridHandoffActivationTests {
    private struct FixedVideoSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("handoff-activation.mp4")
        }
    }

    private static func page() -> ForYouGridPage {
        ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            style: .discover,
            videoPlayback: VideoPlaybackController(source: FixedVideoSource())
        )
    }

    @Test func aHostActivatingItsPageKeepsTheFlightsHandoff() {
        let page = Self.page()
        page.beginPlaybackHandoff(of: PostID("v0"), parkingReturn: true)
        #expect((page.playback?.isHandingOff == true))
        page.setAutoplayActive(true)
        #expect((page.playback?.isHandingOff == true), "the grab's viewWillAppear ended the flight's handoff")
    }

    @Test func theProfilesActivationStillEndsAFinishedRoundTrip() {
        let page = Self.page()
        page.beginPlaybackHandoff(of: PostID("v0"), parkingReturn: true)
        page.setPageActive(true)
        #expect(!(page.playback?.isHandingOff == true), "the profile's way back left the round trip open")
    }
}
