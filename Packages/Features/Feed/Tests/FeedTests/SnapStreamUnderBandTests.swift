import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// THE STREAM UNDER THE BAND (the owner, 2026-10-16 — the experiment of
/// #1244, kept): the streaming comments on the caption, the danmaku band
/// above them, its trailing end faded short of the rail — and the
/// engagement corner on the band's SEAT, never on the band.
@MainActor
struct SnapStreamUnderBandTests {
    private static func chrome(reactions: Int = 8, cues: Int = 2) -> SnapChromeView {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
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
            reactions: (0..<reactions).map { TickerCommentModel(id: "r\($0)", text: "fire \($0)") },
            subtitles: (0..<cues).map { SubtitleCue(id: "s\($0)", text: "A whole sentence worth reading \($0).") },
            commentCount: reactions + cues
        ))
        chrome.layoutIfNeeded()
        return chrome
    }

    /// The band stands one md above the stream, short of the rail.
    @Test func theBandRidesAboveTheStream() {
        let chrome = Self.chrome()
        #expect(abs(chrome.debugBandFrame.maxY - (chrome.debugStreamFrame.minY - Spacing.md)) < 0.5)
        #expect(chrome.debugBandFrame.maxX <= chrome.debugRailFrame.minX - Spacing.md + 0.5)
    }

    /// The stream holds its seat whether or not the band renders.
    @Test func theStreamHoldsItsSeat() {
        let dense = Self.chrome()
        let sparse = Self.chrome(reactions: 0)
        #expect(abs(dense.debugStreamFrame.maxY - sparse.debugStreamFrame.maxY) < 0.5)
    }

    /// The rail hangs off the band's seat: the band's comings and goings
    /// never move it.
    @Test func theEngagementCornerDoesNotMove() {
        let dense = Self.chrome()
        let sparse = Self.chrome(reactions: 0)
        #expect(dense.debugRailFrame == sparse.debugRailFrame)
    }

    /// The band's trailing end fades over `trailingFadeLength` instead of
    /// being cut to a capsule.
    @Test func theBandsTrailingEndFades() throws {
        let chrome = Self.chrome()
        let end = chrome.debugBandTrailingEnd
        #expect(end.cornerRadius == 0, "the band's end is still cut round")
        let stops = try #require(end.fadeLocations).map(\.doubleValue)
        let width = Double(chrome.debugBandFrame.width)
        #expect(stops.count == 3)
        #expect(abs(stops[1] - (1 - Double(SnapCommentTickerView.trailingFadeLength) / width)) < 0.001)
        #expect(stops[2] == 1)
    }
}
