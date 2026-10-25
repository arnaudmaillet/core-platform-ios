import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Feed

/// #1724: the scrub card in the clip's own shape, and the flight replica's
/// caption at the landing page's seat.
@MainActor
struct SnapScrubPreviewShapeTests {
    /// Landscape: 118 pt wide. Portrait: 150 pt tall, as narrow as the clip.
    @Test func theCardTakesTheClipsShape() {
        let landscape = SnapScrubPreviewView.frameSize(aspect: 16.0 / 9.0)
        #expect(landscape.width == SnapScrubPreviewView.maxFrameWidth)
        #expect(abs(landscape.height - 66) <= 1)

        let portrait = SnapScrubPreviewView.frameSize(aspect: 9.0 / 16.0)
        #expect(portrait.height == SnapScrubPreviewView.maxFrameHeight)
        #expect(abs(portrait.width / portrait.height - 9.0 / 16.0) < 0.01, "a vertical clip's card is not vertical")
    }

    /// A frame arriving in another shape than declared reshapes the card.
    @Test func aFrameOfAnotherShapeReshapesTheCard() throws {
        let card = SnapScrubPreviewView()
        card.aspect = 16.0 / 9.0
        var reshaped = false
        card.onShapeChange = { reshaped = true }
        let context = try #require(CGContext(
            data: nil, width: 90, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        card.setPicture(try #require(context.makeImage()))
        #expect(reshaped)
        #expect(abs(card.aspect - 90.0 / 160.0) < 0.01)
    }

    /// ⚠️ The caption's seat is applied at `configure`: a replica that never
    /// receives a page count (a single picture's flight) stands where the page
    /// will — the caption on the cover's line.
    @Test func aReplicaTakesTheCaptionSeatAtConfigure() {
        let replica = SnapChromeView(frame: SnapActionColumnLayoutTests.screen)
        replica.setFixedInsets(SnapActionColumnLayoutTests.insets)
        replica.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
        replica.configure(with: SnapActionColumnLayoutTests.mediaModel(mediaURL: URL(string: "mock://media/1")))
        replica.layoutIfNeeded()

        let page = SnapActionColumnLayoutTests.chrome()
        page.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
        page.setMediaPageCount(1, current: 0)
        page.layoutIfNeeded()
        #expect(abs(replica.debugCaptionFrame.maxY - page.debugCaptionFrame.maxY) < 0.5,
                "the replica's caption flies at \(replica.debugCaptionFrame.maxY), the page's lands at \(page.debugCaptionFrame.maxY)")
    }
}
