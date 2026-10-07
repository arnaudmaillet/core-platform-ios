import Foundation
import MediaCore
import Testing
import UIKit
@testable import Maps

/// The marker's preview sheet and the page's live video, lined up (#625).
///
/// Asserted through the static rules: this target never instantiates an
/// `MKMapView` (see `MapAnnotationPopTests`), and the rules are where the
/// numbers live.
@MainActor
struct MapFlightMediaSyncTests {
    /// 12 frames of 0.1 s cut from 1.0 s into the clip: a 1.2 s window.
    private func sheet(startTime: TimeInterval? = 1.0) -> AnimatedIconSheet {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { _ in }
        return AnimatedIconSheet(sheet: image, frameCount: 12, columns: 4, frameDuration: 0.1, startTime: startTime)
    }

    @Test("The page starts a lead ahead of the marker's frame, for what the flight and the first decode take")
    func thePageStartsAheadOfTheMarker() throws {
        let time = try #require(MapPinZoomSource.flightMediaTime(sheet: sheet(), displayedFrame: 2))
        #expect(abs(time - (1.2 + MapPinZoomSource.flightMediaLead)) < 1e-9)
    }

    @Test("Never past the sheet's end, so the video lands inside the window the card can line up on")
    func theStartStaysInsideTheWindow() throws {
        let time = try #require(MapPinZoomSource.flightMediaTime(sheet: sheet(), displayedFrame: 11))
        #expect(abs(time - (1.0 + 1.2 - MapPinZoomSource.flightMediaTailMargin)) < 1e-9)
    }

    @Test("A sheet with no clip start gives the page nothing: it starts at zero, as before")
    func noStartNoTime() {
        #expect(MapPinZoomSource.flightMediaTime(sheet: sheet(startTime: nil), displayedFrame: 2) == nil)
    }

    @Test("The phase that shows a frame now rotates the shared clock by the difference, wrapping")
    func phaseRotation() {
        #expect(PinCardView.phase(showing: 9, now: 10, currentPhase: 0, frameCount: 12) == 11)
        #expect(PinCardView.phase(showing: 2, now: 10, currentPhase: 3, frameCount: 12) == 7)
        #expect(PinCardView.phase(showing: 5, now: 5, currentPhase: 4, frameCount: 12) == 4)
        #expect(PinCardView.phase(showing: 1, now: 0, currentPhase: 4, frameCount: 0) == 4)
    }

    @Test("The focus pull starts at the sheet's resolution on the video's surface")
    func theSheetsResolution() throws {
        // A 168x300 cell covering a 402x874 surface: the tighter axis decides,
        // as aspect-fill does.
        let ppp = try #require(PinCardView.sheetPixelsPerPoint(cell: CGSize(width: 168, height: 300),
                                                                covering: CGSize(width: 402, height: 874)))
        #expect(abs(ppp - 300.0 / 874) < 1e-9)
        #expect(PinCardView.sheetPixelsPerPoint(cell: .zero, covering: CGSize(width: 1, height: 1)) == nil)
        #expect(PinCardView.sheetPixelsPerPoint(cell: CGSize(width: 1, height: 1), covering: .zero) == nil)
    }
}
