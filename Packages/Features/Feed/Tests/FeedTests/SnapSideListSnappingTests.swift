import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The side list comes to rest on whole tiles, and blurs an edge only while
/// a tile is cut there (#1527).
@MainActor
struct SnapSideListSnappingTests {
    typealias Snapping = SnapSideList.Snapping

    /// Ten 100 pt tiles, 6 pt apart, in a 330 pt list: 3.2 tiles show.
    private static let tiles = (0..<10).map { CGRect(x: 0, y: CGFloat($0) * 106, width: 75, height: 100) }
    private static let viewport: CGFloat = 330
    private static var contentHeight: CGFloat { tiles.last!.maxY }

    private static func target(_ proposed: CGFloat, _ direction: Snapping.Direction) -> CGFloat {
        Snapping.target(
            proposed: proposed, direction: direction, tiles: tiles, viewport: viewport, contentHeight: contentHeight
        )
    }

    // MARK: - Snapping

    /// ⚠️ GOING DOWN, THE TOP TILE WHOLE ON THE TOP EDGE: the tile edge
    /// nearest where the scroll would have stopped.
    @Test func goingDownSettlesATileTopOnTheTopEdge() {
        #expect(Self.target(140, .down) == 106, "a cut top tile, not aligned")
        #expect(Self.target(190, .down) == 212)
        #expect(Self.target(212, .down) == 212, "an aligned rest moved")
    }

    /// ⚠️ GOING UP, THE BOTTOM TILE WHOLE ON THE BOTTOM EDGE.
    @Test func goingUpSettlesATileBottomOnTheBottomEdge() {
        let settled = Self.target(140, .up)
        #expect(Self.tiles.contains { $0.maxY == settled + Self.viewport }, "the bottom edge cuts a tile at \(settled)")
        #expect(settled == 100 + 212 + 106 - Self.viewport, "not the nearest bottom alignment: \(settled)")
    }

    /// A flick crosses many tiles and still lands aligned, within the
    /// content.
    @Test func aFlickLandsAlignedWithinTheContent() {
        let far = Self.target(610, .down)
        #expect(Self.tiles.contains { $0.minY == far })
        #expect(Self.target(5_000, .down) == Self.contentHeight - Self.viewport, "past the end")
        #expect(Self.target(-300, .up) == 0, "before the start")
    }

    // MARK: - Revealing a cut tile

    /// ⚠️ A CUT TILE COMES WHOLE ON THE EDGE THAT CUT IT, BY THE LEAST
    /// SCROLL; a whole one does not move.
    @Test func aCutTileIsRevealedOnItsEdge() {
        let second = Self.tiles[1]
        #expect(Snapping.reveal(second, offset: 140, viewport: Self.viewport) == 106, "cut at the top")
        let fourth = Self.tiles[3]
        #expect(Snapping.reveal(fourth, offset: 0, viewport: Self.viewport) == fourth.maxY - Self.viewport, "cut at the bottom")
        #expect(Snapping.reveal(Self.tiles[1], offset: 0, viewport: Self.viewport) == nil, "a whole tile moved")
    }

    // MARK: - The edge blurs

    /// ⚠️ AN EDGE BLURS ONLY WHILE IT CUTS A TILE, as much as it cuts it.
    @Test func anEdgeBlursOnlyWhileItCutsATile() {
        let aligned = Snapping.cuts(offset: 106, viewport: Self.viewport, tiles: Self.tiles)
        #expect(aligned.top == 0, "an aligned top edge cut a tile")
        #expect(aligned.bottom > 0, "guard: 330 pt never ends on a tile's edge here")
        let midTile = Snapping.cuts(offset: 130, viewport: Self.viewport, tiles: Self.tiles)
        #expect(midTile.top == 24)
        let inGap = Snapping.cuts(offset: 103, viewport: Self.viewport, tiles: Self.tiles)
        #expect(inGap.top == 0, "an edge in the gap between tiles cut one")
        let atRest = Snapping.cuts(offset: Self.target(140, .up), viewport: Self.viewport, tiles: Self.tiles)
        #expect(atRest.bottom == 0, "the snapped bottom edge still cut a tile")
    }

    /// The strength eases in and out with the cut: none at zero, full past
    /// the ramp, smooth in between — no pop.
    @Test func theBlurEasesWithTheCut() {
        #expect(Snapping.blurStrength(cut: 0) == 0)
        #expect(Snapping.blurStrength(cut: Snapping.blurRamp) == 1)
        #expect(Snapping.blurStrength(cut: 100) == 1)
        let steps = stride(from: 0, through: Snapping.blurRamp, by: 1).map { Snapping.blurStrength(cut: $0) }
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $1 >= $0 }, "not monotonic")
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $1 - $0 < 0.1 }, "a jump in the ramp")
    }

    // MARK: - The view

    private static func entry(_ id: String) -> FeedEntry {
        FeedEntry(
            post: Post(
                id: PostID(id), authorID: ProfileID("p"), caption: "",
                attachments: [MediaAttachment(
                    url: URL(string: "https://cdn.example/\(id).jpg"), thumbnailURL: nil,
                    mimeType: "image/jpeg", pixelWidth: 1080, pixelHeight: 1350
                )],
                publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }

    /// The list's own blurs follow its scroll.
    @Test func theListBlursItsCutEdge() throws {
        let list = SnapSideListView(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        list.frame = CGRect(x: 0, y: 0, width: 75, height: 330)
        list.layoutIfNeeded()
        list.show((0..<10).map { Self.entry("m\($0)") })
        let frames = list.debugTileFrames
        try #require(frames.count == 10, "guard: the tiles laid out")

        list.debugOffset = 0
        #expect(list.debugBlurStrengths.top == 0, "the top blurs at the top of the list")
        list.debugOffset = frames[1].minY + 30
        #expect(list.debugBlurStrengths.top == 1, "a tile cut 30 pt at the top, no blur")
        list.debugOffset = frames[1].minY
        #expect(list.debugBlurStrengths.top == 0, "an aligned top edge still blurs")
    }
}
