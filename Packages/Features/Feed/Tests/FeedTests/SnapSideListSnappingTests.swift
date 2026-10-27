import DesignSystem
import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The side list comes to rest on whole tiles by one rule (#1527, #1545),
/// and its tiles wear a skeleton while their media is on its way (#1553).
@MainActor
struct SnapSideListSnappingTests {
    typealias Snapping = SnapSideList.Snapping

    /// Ten 100 pt tiles, 6 pt apart, in a list of exactly three: 318 pt.
    private static let tiles = (0..<10).map { CGRect(x: 0, y: CGFloat($0) * 106, width: 75, height: 100) }
    private static let viewport: CGFloat = 3 * 100 + 2 * 6
    private static var contentHeight: CGFloat { tiles.last!.maxY }

    private static func target(_ proposed: CGFloat) -> CGFloat {
        Snapping.target(proposed: proposed, tiles: tiles, viewport: viewport, contentHeight: contentHeight)
    }

    // MARK: - Snapping

    /// ⚠️ ONE RULE (#1545): a tile's top on the top edge, the nearest — and
    /// with whole tiles in the list, the bottom tile is whole too, whichever
    /// way the scroll went.
    @Test func aReleaseSettlesATileTopOnTheTopEdge() {
        #expect(Self.target(140) == 106, "a cut top tile, not aligned")
        #expect(Self.target(190) == 212)
        #expect(Self.target(212) == 212, "an aligned rest moved")
        let settled = Self.target(140)
        #expect(Self.tiles.contains { $0.maxY == settled + Self.viewport }, "the bottom edge cuts a tile at \(settled)")
    }

    /// A flick crosses many tiles and still lands aligned, within the
    /// content.
    @Test func aFlickLandsAlignedWithinTheContent() {
        let far = Self.target(610)
        #expect(Self.tiles.contains { $0.minY == far })
        #expect(Self.target(5_000) == Self.contentHeight - Self.viewport, "past the end")
        #expect(Self.target(-300) == 0, "before the start")
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

    // MARK: - The skeletons (#1553)

    private static func entry(_ id: String, media: Bool = true) -> FeedEntry {
        FeedEntry(
            post: Post(
                id: PostID(id), authorID: ProfileID("p"), caption: "words \(id)",
                attachments: media ? [MediaAttachment(
                    url: URL(string: "https://cdn.example/\(id).jpg"), thumbnailURL: nil,
                    mimeType: "image/jpeg", pixelWidth: 1080, pixelHeight: 1350
                )] : [],
                publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }

    /// A fetcher that never answers: every cover stays on its way.
    private struct PendingFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data {
            try await Task.sleep(for: .seconds(3_600))
            return Data()
        }
    }

    private func makeList(_ entries: [FeedEntry]) -> SnapSideListView {
        let list = SnapSideListView(imagePipeline: ImagePipeline(fetcher: PendingFetcher()))
        list.frame = CGRect(x: 0, y: 0, width: 62, height: 674)
        list.tileSize = CGSize(width: 62, height: 62)
        list.layoutIfNeeded()
        list.show(entries)
        list.layoutIfNeeded()
        return list
    }

    /// A media tile still waiting for its cover wears ONE shimmering bone —
    /// its cover's own (#1772), on the page's black — and a text tile (its
    /// words) none.
    @Test func aWaitingMediaTileWearsItsOwnBoneAndATextTileNone() async throws {
        let list = makeList([Self.entry("m0"), Self.entry("t1", media: false)])
        let cells = list.debugTileCells
        try #require(cells.count == 2, "guard: the tiles laid out")
        let media = try #require(cells.first { !$0.showsInfo })
        let text = try #require(cells.first { $0.showsInfo })
        for _ in 0..<200 where !media.showsCoverBone { try? await Task.sleep(for: .milliseconds(5)) }
        let bones = list.debugBones(on: media)
        #expect(bones.count == 1, "a second bone over the tile's own")
        #expect(bones.first?.fill == Surface.mediaGroundOnDark)
        #expect(media.contentView.backgroundColor == Surface.mediaGroundOnDark)
        #expect(list.debugBones(on: text).isEmpty, "a text tile wears a bone")
    }

    // MARK: - No scroll while the list opens (#1580)

    /// ⚠️ THE OWNER'S RECORDING (2026-10-22): the list loads as a swipe
    /// begins, often at once, before any pose has given it a height. Its
    /// outline then "revealed" the first tile against a 0-pt viewport and
    /// scrolled a tile and a half past it for the whole opening, until the
    /// settle's outline scrolled back. A list with no height never scrolls.
    @Test func aListWithNoHeightYetNeverScrolls() {
        let list = SnapSideListView(imagePipeline: ImagePipeline(fetcher: PendingFetcher()))
        list.tileSize = CGSize(width: 47, height: 62)
        list.show((0..<14).map { Self.entry("m\($0)") })
        list.outline(PostID("m0"))
        #expect(list.debugOffset == 0, "the list scrolled against an empty viewport")
        // The opening places it: still on its first tile.
        list.frame = CGRect(x: 0, y: 0, width: 47, height: 674)
        list.layoutIfNeeded()
        list.outline(PostID("m0"))
        #expect(list.debugOffset == 0, "the first tile, already whole, moved")
    }

    /// A new list starts at its top — its first tile is the post on show —
    /// whatever the last list was scrolled to.
    @Test func aNewListStartsAtItsTop() {
        let list = makeList((0..<20).map { Self.entry("a\($0)") })
        list.debugOffset = 300
        list.show((0..<20).map { Self.entry("b\($0)") })
        #expect(list.debugOffset == 0)
    }

    /// The list's viewport is rounded like a tile: a tile scrolled half out
    /// is cut on a curve, never on a flat line (the owner, 2026-10-22).
    @Test func theListsEdgesWearTheTilesCorner() {
        let list = makeList((0..<14).map { Self.entry("m\($0)") })
        #expect(list.debugViewportCornerRadius == SnapSideList.Geometry.tileCornerRadius)
    }

    /// The list's tiles are the geometry's size (#1545).
    @Test func theTilesAreTheGeometrysSize() throws {
        let list = makeList((0..<12).map { Self.entry("m\($0)") })
        let frames = list.debugTileFrames
        try #require(frames.count == 12)
        #expect(frames.allSatisfy { $0.size == CGSize(width: 62, height: 62) })
        #expect(frames[1].minY - frames[0].maxY == SnapSideList.Geometry.tileSpacing)
    }
}
