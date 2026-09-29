import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// For You's rows come to rest on an item's edge, the side picked by the
/// gesture (2026-09-29): forward puts an item's trailing edge on the right
/// margin with nothing to its right, back puts one's leading edge on the left
/// margin with nothing to its left — and the rows' sizes leave an item
/// cropped on the other side in both cases.
@MainActor
struct ForYouRowSnapTests {
    typealias Metrics = ForYouRailsView.Metrics

    /// A row of `count` items `width` wide, laid out the way the rows' flow
    /// layout lays them: the side margin, then items `itemGap` apart.
    @MainActor private struct Row {
        let viewport: CGFloat
        let items: [ClosedRange<CGFloat>]
        var margin: CGFloat { Metrics.sideMargin }
        var offsets: ClosedRange<CGFloat> {
            0...max(0, (items.last?.upperBound ?? 0) + margin - viewport)
        }

        init(viewport: CGFloat, itemWidth: CGFloat, count: Int) {
            self.viewport = viewport
            items = (0..<count).map { index in
                let minX = Metrics.sideMargin + CGFloat(index) * (itemWidth + Metrics.itemGap)
                return minX...(minX + itemWidth)
            }
        }

        static func cards(_ viewport: CGFloat, count: Int = 8) -> Row {
            Row(viewport: viewport, itemWidth: Metrics.cardSize(forWidth: viewport).width, count: count)
        }

        static func stories(_ viewport: CGFloat, count: Int = 12) -> Row {
            Row(viewport: viewport, itemWidth: Metrics.storySize(forWidth: viewport).width, count: count)
        }

        func snap(_ projected: CGFloat, _ direction: ForYouRowSnap.Direction?) -> CGFloat {
            ForYouRowSnap.target(
                projected: projected, direction: direction, items: items,
                viewport: viewport, margin: margin, offsets: offsets
            )
        }

        /// The items' extents on screen at `offset`.
        func onScreen(at offset: CGFloat) -> [ClosedRange<CGFloat>] {
            items.map { ($0.lowerBound - offset)...($0.upperBound - offset) }
        }

        /// Whether an item's leading edge is on the left margin at `offset`.
        func isLeadingAligned(_ offset: CGFloat) -> Bool {
            onScreen(at: offset).contains { $0.lowerBound == margin }
        }

        /// Whether an item's trailing edge is on the right margin at `offset`.
        func isTrailingAligned(_ offset: CGFloat) -> Bool {
            onScreen(at: offset).contains { $0.upperBound == viewport - margin }
        }

        /// Whether any item shows a part of itself — not all of it — at `offset`
        /// on the left edge, or on the right edge.
        func isCroppedOnLeft(_ offset: CGFloat) -> Bool {
            onScreen(at: offset).contains { $0.lowerBound < 0 && $0.upperBound > 0 }
        }

        func isCroppedOnRight(_ offset: CGFloat) -> Bool {
            onScreen(at: offset).contains { $0.lowerBound < viewport && $0.upperBound > viewport }
        }

        /// Whether nothing at all is drawn left of the left margin / right of
        /// the right margin at `offset`.
        func isEmptyOnLeft(_ offset: CGFloat) -> Bool {
            !onScreen(at: offset).contains { $0.lowerBound < margin && $0.upperBound > 0 }
        }

        func isEmptyOnRight(_ offset: CGFloat) -> Bool {
            !onScreen(at: offset).contains { $0.upperBound > viewport - margin && $0.lowerBound < viewport }
        }
    }

    nonisolated private static let widths: [CGFloat] = [375, 393, 402, 440]

    // MARK: - The geometry

    /// The gap is at least the margin — the one condition that lets a snap
    /// leave its hidden side EMPTY rather than showing a sliver.
    @Test func theGapIsAtLeastTheMargin() {
        #expect(Metrics.itemGap >= Metrics.sideMargin)
    }

    /// On every phone width and in both rows, the start shows nothing on the
    /// left and an item cropped on the right, and a rest flush right shows
    /// nothing on the right and an item cropped on the left.
    @Test(arguments: widths)
    func bothRowsCropOneSideAndEmptyTheOther(width: CGFloat) {
        for (name, row) in [("cards", Row.cards(width)), ("stories", Row.stories(width))] {
            #expect(row.isLeadingAligned(0) && row.isEmptyOnLeft(0), "\(name)@\(width): the start")
            #expect(row.isCroppedOnRight(0), "\(name)@\(width): an item peeks on the right at the start")

            let forward = row.snap(1, .forward)
            #expect(forward > 0, "\(name)@\(width): a forward swipe moves")
            #expect(row.isTrailingAligned(forward), "\(name)@\(width): flush right")
            #expect(row.isEmptyOnRight(forward), "\(name)@\(width): nothing right of the right margin")
            #expect(row.isCroppedOnLeft(forward), "\(name)@\(width): the one before peeks on the left")

            let back = row.snap(forward - 1, .backward)
            #expect(row.isLeadingAligned(back) && row.isEmptyOnLeft(back), "\(name)@\(width): flush left")
            #expect(row.isCroppedOnRight(back), "\(name)@\(width): the next peeks on the right")
        }
    }

    /// Following stays about 2.3 cards wide; Friends shows four faces and a
    /// fifth cropped, on every width.
    @Test(arguments: widths)
    func theRowsShowTheirCounts(width: CGFloat) {
        let cards = Row.cards(width).onScreen(at: 0).filter { $0.lowerBound < width }
        #expect(cards.count == 3, "two cards and a third peeking at \(width)")
        let stories = Row.stories(width).onScreen(at: 0).filter { $0.lowerBound < width }
        #expect(stories.count == 5, "four faces and a fifth peeking at \(width)")
        let face = ForYouStoryCell.Metrics.faceDiameter(discSide: Metrics.storySize(forWidth: width).width)
        #expect((50...80).contains(face), "a face \(face) across at \(width)")
    }

    // MARK: - The target

    /// Forward reveals the item the projection cuts at the right margin — a
    /// nudge the next one, never a return to the start.
    @Test func forwardRevealsTheItemCutAtTheRight() {
        let row = Row.cards(393)
        let nudge = row.snap(4, .forward)
        // Card 2 was the one peeking: it comes all the way in.
        #expect(row.items[2].upperBound - nudge == row.viewport - row.margin)

        // A fling projected past card 4's start reveals card 4 (or the end).
        let far = row.items[4].lowerBound - row.margin
        let flung = row.snap(far, .forward)
        #expect(flung >= far && row.isTrailingAligned(flung))
    }

    /// Back is the mirror: the item the projection cuts at the left margin.
    @Test func backRevealsTheItemCutAtTheLeft() {
        let row = Row.cards(393)
        let resting = row.items[5].upperBound + row.margin - row.viewport
        let back = row.snap(resting - 4, .backward)
        #expect(back < resting && row.isLeadingAligned(back))
        #expect(row.isEmptyOnLeft(back))
    }

    /// A rest already on an anchor is kept by a projection a hair short of
    /// it, not pushed a whole item on.
    @Test func aRestOnAnAnchorStays() {
        let row = Row.cards(393)
        let resting = row.snap(4, .forward)
        #expect(row.snap(resting - 0.25, .forward) == resting)
    }

    /// The ends: never past either, and the end is flush right.
    @Test func theEndsAreTheRowsOwn() {
        let row = Row.stories(402)
        #expect(row.snap(-50, .backward) == 0)
        #expect(row.snap(10_000, .forward) == row.offsets.upperBound)
        #expect(row.isTrailingAligned(row.offsets.upperBound))
        #expect(row.snap(row.offsets.upperBound + 30, .forward) == row.offsets.upperBound)
    }

    /// No direction — a drag with no speed and no movement worth the name —
    /// takes the nearest anchor of either kind.
    @Test func noDirectionTakesTheNearest() {
        let row = Row.cards(393)
        let trailing2 = row.items[2].upperBound + row.margin - row.viewport
        #expect(row.snap(trailing2 + 3, nil) == trailing2)
        #expect(row.snap(2, nil) == 0)
    }

    /// A row shorter than the screen does not move.
    @Test func aShortRowStaysPut() {
        let row = Row(viewport: 393, itemWidth: 60, count: 2)
        #expect(row.offsets == 0...0)
        #expect(row.snap(20, .forward) == 0)
        #expect(row.snap(20, .backward) == 0)
    }

    // MARK: - The direction

    /// The release's speed decides; without speed, the drag's last movement;
    /// without either, nothing (and the nearest rest).
    @Test func theDirectionIsTheGesturesOwn() {
        #expect(ForYouRowSnap.direction(velocity: 1.2, lastMovement: .backward) == .forward)
        #expect(ForYouRowSnap.direction(velocity: -0.8, lastMovement: .forward) == .backward)
        #expect(ForYouRowSnap.direction(velocity: 0, lastMovement: .backward) == .backward)
        #expect(ForYouRowSnap.direction(velocity: 0.02, lastMovement: .forward) == .forward)
        #expect(ForYouRowSnap.direction(velocity: 0, lastMovement: nil) == nil)
    }

    /// The last movement is the last RUN the finger made, not the net drag,
    /// and a jitter of a point does not count as one.
    @Test func theLastMovementIsTheLastRun() {
        var tracker = ForYouRowDragTracker(offset: 100)
        tracker.track(101)
        #expect(tracker.lastMovement == nil, "a point is a jitter")
        for x in stride(from: 102, through: 160, by: 4) { tracker.track(CGFloat(x)) }
        #expect(tracker.lastMovement == .forward)
        tracker.track(157)
        tracker.track(158)
        #expect(tracker.lastMovement == .forward, "a hand at rest shakes; it does not turn back")
        for x in stride(from: 156, through: 130, by: -3) { tracker.track(CGFloat(x)) }
        #expect(tracker.lastMovement == .backward, "eased back: the second thought wins, net forward or not")
    }

    // MARK: - Through the row itself

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func post(_ id: String) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.com/\(id).jpg"),
            caption: "caption \(id)", publishedAtMS: 1,
            authorID: ProfileID("a-\(id)"), authorName: "A", authorHandle: "a"
        )
    }

    /// The real Following row, released with a forward flick from the start
    /// through its own delegate: it rests flush right on a card, with the
    /// next card wholly off screen.
    @Test func theFollowingRowSnapsThroughItsDelegate() throws {
        let rails = ForYouRailsView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), videoPlayback: nil)
        rails.frame = CGRect(x: 0, y: 0, width: 393, height: 800)
        var state = ForYouViewModel.Rails()
        state.following = (0..<8).map { post("c\($0)") }
        rails.render(state)
        rails.layoutIfNeeded()
        let row = try #require(rails.subviews.compactMap { $0 as? UICollectionView }.last)
        row.layoutIfNeeded()

        var target = CGPoint(x: 40, y: 0)
        rails.scrollViewWillEndDragging(row, withVelocity: CGPoint(x: 1.5, y: 0), targetContentOffset: &target)
        let frames = (0..<8).compactMap { row.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
        let flushRight = try #require(frames.first { $0.maxX - target.x == row.bounds.width - Metrics.sideMargin })
        let next = try #require(frames.first { $0.minX > flushRight.maxX })
        #expect(next.minX - target.x >= row.bounds.width, "nothing to the right of the snapped card")

        var back = CGPoint(x: target.x - 20, y: 0)
        rails.scrollViewWillEndDragging(row, withVelocity: CGPoint(x: -1.5, y: 0), targetContentOffset: &back)
        #expect(back.x == 0, "back to the start, flush left")
    }
}
