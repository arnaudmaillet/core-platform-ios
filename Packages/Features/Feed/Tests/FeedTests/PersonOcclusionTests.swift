import AVFoundation
import CoreStorage
import CoreVideo
import Foundation
import Testing
import UIKit
@testable import Feed

/// "Don't Cover People" (#484): when segmentation runs, what a beat does,
/// where the mask lands, and the switch itself.
@MainActor
struct PersonOcclusionTests {
    private let open = PersonOcclusionGate.Inputs(
        enabled: true, bandShown: true, pageActive: true, playing: true, inFlight: false,
        powerSaving: false, lowPowerMode: false, thermalState: .nominal
    )

    /// Every rule closes the gate on its own; all clear, it opens.
    @Test func eachRuleClosesTheGate() {
        #expect(PersonOcclusionGate.isOpen(open))
        var closed = open
        closed.enabled = false
        #expect(!PersonOcclusionGate.isOpen(closed), "the setting is off")
        closed = open
        closed.bandShown = false
        #expect(!PersonOcclusionGate.isOpen(closed), "no band to mask")
        closed = open
        closed.pageActive = false
        #expect(!PersonOcclusionGate.isOpen(closed), "off screen: segmentation stops")
        closed = open
        closed.inFlight = true
        #expect(!PersonOcclusionGate.isOpen(closed), "during a hero flight")
        closed = open
        closed.powerSaving = true
        #expect(!PersonOcclusionGate.isOpen(closed), "Power Saving")
        closed = open
        closed.lowPowerMode = true
        #expect(!PersonOcclusionGate.isOpen(closed), "Low Power Mode")
        closed = open
        closed.thermalState = .serious
        #expect(!PersonOcclusionGate.isOpen(closed), "a hot device")
        closed.thermalState = .fair
        #expect(PersonOcclusionGate.isOpen(closed), "fair is still fine")
    }

    /// A paused clip keeps its mask; anything else that closes the gate
    /// removes it.
    @Test func aPauseHoldsTheMaskAndTheRestClearsIt() {
        #expect(PersonOcclusionDriver.decision(for: open) == .segment)
        var paused = open
        paused.playing = false
        #expect(PersonOcclusionDriver.decision(for: paused) == .hold)
        var away = paused
        away.pageActive = false
        #expect(PersonOcclusionDriver.decision(for: away) == .clear, "paused AND off screen is off screen")
        var hot = open
        hot.thermalState = .critical
        #expect(PersonOcclusionDriver.decision(for: hot) == .clear)
    }

    /// The mask is drawn where the video's pixels land: fitted inside the
    /// page, or filling it and cropped.
    @Test func theMaskFollowsTheVideosFraming() {
        let page = CGRect(x: 0, y: 0, width: 400, height: 800)
        let landscape = CGSize(width: 1920, height: 1080)
        let fitted = PersonOcclusionGeometry.displayedRect(of: landscape, in: page, gravity: .resizeAspect)
        #expect(abs(fitted.width - 400) < 0.01)
        #expect(abs(fitted.height - 225) < 0.01)
        #expect(abs(fitted.midY - 400) < 0.01)

        let portrait = CGSize(width: 1080, height: 1920)
        let filled = PersonOcclusionGeometry.displayedRect(of: portrait, in: page, gravity: .resizeAspectFill)
        #expect(filled.height >= 800 && filled.width >= 400)
        #expect(abs(filled.midX - 200) < 0.01)
    }

    /// Outside the picture (letterbox bars) the band is never cut: the mask
    /// is opaque there, and carries the person mask only over the picture.
    @Test func outsideThePictureTheBandShows() throws {
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }.cgImage)
        let mask = PersonOcclusionGeometry.MaskLayer()
        let band = CGRect(x: 0, y: 0, width: 300, height: 40)
        let picture = CGRect(x: 0, y: -100, width: 300, height: 120)
        mask.update(bounds: band, imageRect: picture, image: image, fade: 0)
        #expect(mask.picture.frame == picture)
        #expect(mask.surround.fillRule == .evenOdd)
        let path = try #require(mask.surround.path)
        #expect(path.contains(CGPoint(x: 150, y: 10), using: .evenOdd) == false, "inside the picture: the person mask decides")
        let letterboxed = CGRect(x: 50, y: 0, width: 200, height: 40)
        mask.update(bounds: band, imageRect: letterboxed, image: image, fade: 0)
        #expect(mask.surround.path?.contains(CGPoint(x: 10, y: 20), using: .evenOdd) == true, "a bar beside the picture shows the band")
    }

    /// Vision runs on a frame without trapping, off the main thread, and
    /// answers an alpha mask (or nothing, where segmentation is unavailable).
    @Test func theSegmenterAnswersOffTheMainThread() async throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 96, kCVPixelFormatType_32BGRA, nil, &buffer)
        nonisolated(unsafe) let frame = try #require(buffer)
        let segmenter = PersonSegmenter()
        if let mask = await segmenter.mask(for: frame) {
            #expect(mask.width > 0 && mask.height > 0)
        }
    }

    /// Off by default; preferences saved before the switch keep the rest.
    @Test func theSwitchIsOffByDefaultAndOldPreferencesStillRead() throws {
        #expect(!MediaCommentPreferences().avoidsPeople)
        let saved = #"{"showsReactionBand":false,"bandSpeed":"fast"}"#
        let decoded = try JSONDecoder().decode(MediaCommentPreferences.self, from: Data(saved.utf8))
        #expect(!decoded.avoidsPeople)
        #expect(!decoded.showsReactionBand)
        var turnedOn = decoded
        turnedOn.avoidsPeople = true
        let roundTrip = try JSONDecoder().decode(MediaCommentPreferences.self, from: JSONEncoder().encode(turnedOn))
        #expect(roundTrip.avoidsPeople)
    }
}
