import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// ⚠️ EXPERIMENTAL (`-snap-stream-under-band`, the owner 2026-10-15): the
/// streaming comments in the band's seat on the caption, the danmaku band
/// above them — and the engagement corner exactly where it always is.
@MainActor
struct SnapStreamUnderBandTests {
    private static func chrome(streamsUnderBand: Bool) -> SnapChromeView {
        let chrome = SnapChromeView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844), streamsUnderBand: streamsUnderBand
        )
        chrome.setFixedInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-1"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "A caption long enough to fill both of its lines beside the reserved floor.",
            mediaURL: URL(string: "mock://media/1"),
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: (0..<8).map { TickerCommentModel(id: "r\($0)", text: "fire \($0)") },
            subtitles: (0..<2).map { SubtitleCue(id: "s\($0)", text: "A whole sentence worth reading \($0).") },
            commentCount: 10
        ))
        chrome.layoutIfNeeded()
        return chrome
    }

    @Test func theStreamTakesTheBandsSeatAndTheBandRidesAboveIt() {
        let stock = Self.chrome(streamsUnderBand: false)
        let flagged = Self.chrome(streamsUnderBand: true)
        // The stream sits where the band sits by default…
        #expect(abs(flagged.debugStreamFrame.maxY - stock.debugBandFrame.maxY) < 0.5)
        // …and the band stands one md above it, short of the rail.
        #expect(abs(flagged.debugBandFrame.maxY - (flagged.debugStreamFrame.minY - Spacing.md)) < 0.5)
        #expect(flagged.debugBandFrame.maxX <= flagged.debugRailFrame.minX - Spacing.md + 0.5)
        #expect(flagged.debugBandFrame.height == stock.debugBandFrame.height)
    }

    /// The like pill, the rail and the sound bubble hang off the band's
    /// SEAT, not the band: moving the band moves none of them.
    @Test func theEngagementCornerDoesNotMove() {
        let stock = Self.chrome(streamsUnderBand: false)
        let flagged = Self.chrome(streamsUnderBand: true)
        #expect(flagged.debugRailFrame == stock.debugRailFrame, "\(flagged.debugRailFrame) vs \(stock.debugRailFrame)")
    }

    /// Flagged, the band's trailing end fades over `trailingFadeLength`
    /// instead of being cut to a capsule; the stock band keeps its capsule.
    @Test func theBandsTrailingEndFadesUnderTheFlag() throws {
        let stock = Self.chrome(streamsUnderBand: false)
        let flagged = Self.chrome(streamsUnderBand: true)
        let flaggedEnd = flagged.debugBandTrailingEnd
        #expect(flaggedEnd.cornerRadius == 0, "the band's end is still cut round")
        let stops = try #require(flaggedEnd.fadeLocations).map(\.doubleValue)
        let width = Double(flagged.debugBandFrame.width)
        #expect(stops.count == 3)
        #expect(abs(stops[1] - (1 - Double(SnapCommentTickerView.trailingFadeLength) / width)) < 0.001)
        #expect(stops[2] == 1)
        let stockEnd = stock.debugBandTrailingEnd
        #expect(stockEnd.fadeLocations == nil)
        #expect(stockEnd.cornerRadius == stock.debugBandFrame.height / 2)
    }

    @Test func theStockLayoutIsUnchanged() {
        let stock = Self.chrome(streamsUnderBand: false)
        #expect(!stock.streamsUnderBand)
        #expect(!SnapChromeView.streamsUnderBandByDefault, "the experiment is off unless launched with its argument")
    }
}
