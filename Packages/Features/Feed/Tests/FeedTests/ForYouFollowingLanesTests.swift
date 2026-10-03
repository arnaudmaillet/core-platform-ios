import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The Following row as two lanes (`-foryou-following-two-lanes`, 2026-10-03):
/// media cards on top, text cards twice as wide below, one scroller — and,
/// without the flag, the single-lane row exactly as it was.
@MainActor
struct ForYouFollowingLanesTests {
    private typealias Metrics = ForYouRailsView.Metrics
    private typealias Lanes = ForYouFollowingLanes

    // MARK: - The flag

    @Test func theFlagIsTheLaunchArgument() {
        #expect(Lanes.isEnabled(arguments: ["app", "-foryou-following-two-lanes"]))
        #expect(!Lanes.isEnabled(arguments: ["app", "-foryou-card-likes"]))
        #expect(!Lanes.isEnabled(arguments: []))
    }

    /// ⚠️ FLAG OFF IS TODAY'S ROW: one section in the row's order, the flow
    /// layout, one card tall — mixed kinds and all.
    @Test func withoutTheFlagTheRowIsTheSingleLane() throws {
        let cards = Self.mixed
        let fixture = Fixture(cards: cards, lanes: false)
        let row = try #require(fixture.cardsRow)

        #expect(row.collectionViewLayout is UICollectionViewFlowLayout)
        #expect(row.numberOfSections == 1)
        #expect(row.numberOfItems(inSection: 0) == cards.count)
        for index in cards.indices {
            #expect(fixture.rails.debugCardIndexPath(at: index) == IndexPath(item: index, section: 0))
        }
        let card = Metrics.cardSize(forWidth: 402)
        #expect(row.bounds.height == card.height)
        #expect(ForYouRailsView.height(forWidth: 402, friends: 0, following: cards.count)
            == fixture.rails.preferredHeight(forWidth: 402))
        // Every card, text ones included, is the same card.
        for index in cards.indices {
            #expect(fixture.rails.debugCardLayoutFrame(at: index)?.size == card)
        }
    }

    // MARK: - The partition

    /// Media go to the top lane and words to the bottom one, each in the
    /// row's order; a tap still opens the post it shows.
    @Test func mediaOnTopTextBelowEachInOrder() throws {
        let cards = Self.mixed
        let fixture = Fixture(cards: cards, lanes: true)
        let row = try #require(fixture.cardsRow)

        #expect(row.collectionViewLayout is ForYouFollowingLanesLayout)
        #expect(row.numberOfSections == 2)
        let media = cards.filter { $0.kind != .text }.map(\.id)
        let text = cards.filter { $0.kind == .text }.map(\.id)
        #expect(Lanes.partition(cards).media.map(\.id) == media)
        #expect(Lanes.partition(cards).text.map(\.id) == text)
        for (index, post) in cards.enumerated() {
            let indexPath = try #require(fixture.rails.debugCardIndexPath(at: index))
            let lane = post.kind == .text ? text : media
            #expect(indexPath.section == (post.kind == .text ? 1 : 0))
            #expect(indexPath.item == lane.firstIndex(of: post.id))
        }

        var opened: [Int] = []
        fixture.rails.onCardTapped = { opened.append($0) }
        let firstText = try #require(cards.firstIndex { $0.kind == .text })
        #expect(fixture.rails.debugTapCard(at: firstText))
        #expect(opened == [firstText], "a text card opens its own post")
    }

    // MARK: - The geometry

    /// A text card is two media cards and the gap between them, starting on
    /// an even column, under the media lane — and both lanes are one scroll
    /// view's content.
    @Test(arguments: [375, 402, 440] as [CGFloat])
    func aTextCardSpansTwoColumns(width: CGFloat) throws {
        let cards = Self.mixed
        let fixture = Fixture(cards: cards, lanes: true, width: width)
        let row = try #require(fixture.cardsRow)
        let card = Metrics.cardSize(forWidth: width)
        let gap = Metrics.itemGap
        let media = cards.indices.filter { cards[$0].kind != .text }
        let text = cards.indices.filter { cards[$0].kind == .text }

        let columns = try media.map { try #require(fixture.rails.debugCardLayoutFrame(at: $0)) }
        for (column, frame) in columns.enumerated() {
            #expect(frame.size == card)
            #expect(frame.minY == 0)
            #expect(frame.minX == Metrics.sideMargin + CGFloat(column) * (card.width + gap))
        }
        for (position, index) in text.enumerated() {
            let frame = try #require(fixture.rails.debugCardLayoutFrame(at: index))
            #expect(frame.width == card.width * 2 + gap, "a text card is two media cards and their gap")
            #expect(frame.minY == card.height + gap, "the bottom lane sits under the top one")
            #expect(frame.height == Lanes.textCardHeight)
            #expect(frame.minX == Metrics.sideMargin + CGFloat(position * 2) * (card.width + gap),
                    "a text card starts on an even column")
        }

        // ONE scroll view: both lanes' cells are its subviews, and it is as
        // tall as both lanes and the gap.
        #expect(row.bounds.height == card.height + gap + Lanes.textCardHeight)
        #expect(fixture.rails.subviews.compactMap { $0 as? UICollectionView }.count == 2,
                "the Friends row and ONE Following scroller")
        let sections = Set(row.visibleCells.compactMap { row.indexPath(for: $0)?.section })
        #expect(sections == [0, 1], "both lanes are cells of the same scroller")
        // The content is as wide as the longer lane.
        let geometry = try #require(fixture.rails.debugLanesGeometry)
        let longest = max(media.count, text.count * 2)
        #expect(row.contentSize.width == Metrics.sideMargin * 2 + CGFloat(longest) * (card.width + gap) - gap)
        #expect(geometry.contentSize == row.contentSize)
    }

    /// A lane with nothing in it takes no room: all media is today's height,
    /// all text is the text lane alone.
    @Test func anEmptyLaneTakesNoRoom() {
        let card = Metrics.cardSize(forWidth: 402)
        let media = Lanes.geometry(forWidth: 402, mediaCount: 5, textCount: 0)
        #expect(media.height == card.height)
        let text = Lanes.geometry(forWidth: 402, mediaCount: 0, textCount: 3)
        #expect(text.height == Lanes.textCardHeight)
        #expect(text.textFrame(at: 0).minY == 0)
        #expect(ForYouRailsView.height(forWidth: 402, friends: 0, following: 3, lanes: (0, 3))
            < ForYouRailsView.height(forWidth: 402, friends: 0, following: 3))
    }

    // MARK: - Two lines

    /// The bottom lane's card holds two lines of words and truncates the
    /// rest; today's text card still holds seven.
    @Test func aLaneTextCardShowsTwoLines() throws {
        let long = String(repeating: "A long post that goes on and on. ", count: 12)
        let cards = [Self.post("m0", kind: .photo), Self.post("t0", kind: .text, caption: long)]
        let fixture = Fixture(cards: cards, lanes: true)
        let cell = try #require(fixture.rails.debugCardCell(at: 1))
        cell.layoutIfNeeded()
        let overlay = try #require(Self.overlay(in: cell))
        overlay.layoutIfNeeded()

        #expect(overlay.debugCaptionLines == 2)
        #expect(overlay.debugCaptionHeight <= (overlay.debugCaptionLineHeight * 2).rounded(.up) + 0.5)
        #expect(overlay.debugCaptionHeight > overlay.debugCaptionLineHeight * 1.5, "two lines, not one")
        #expect(overlay.debugAuthorFrame.maxY <= cell.bounds.height, "the author line stays on the card")

        // The flight's copy and the close's stand-in wrap the same way.
        let copy = ForYouFollowingCardCell.makeOverlay(for: cards[1], restingSize: cell.bounds.size)
        #expect(copy.debugCaptionLines == 2)
        let standIn = ForYouFollowingCardCell.makeTextStandIn(for: cards[1], size: cell.bounds.size)
        let standInOverlay = try #require(standIn.subviews.compactMap { $0 as? ForYouCardCaptionOverlay }.first)
        #expect(standInOverlay.debugCaptionLines == 2)

        // Today's tall text card: seven, as before.
        let tall = ForYouFollowingCardCell.makeOverlay(
            for: cards[1], restingSize: Metrics.cardSize(forWidth: 402)
        )
        #expect(tall.debugCaptionLines == ForYouCardCaptionOverlay.textCaptionLines)
    }

    // MARK: - Snapping

    /// With text cards, the row rests on SPREADS — a text card's edges, two
    /// media columns — and the gesture picks the edge: forward, a spread
    /// flush right; back, flush left; the start flush left, the end flush
    /// right.
    @Test(arguments: [375, 402, 440] as [CGFloat])
    func theRowRestsOnSpreads(width: CGFloat) {
        let geometry = Lanes.geometry(forWidth: width, mediaCount: 9, textCount: 3)
        let margin = Metrics.sideMargin
        let pitch = geometry.pitch
        let spreads = geometry.snapExtents
        #expect(spreads.count == 5, "nine columns: four pairs and a last single")
        for (k, spread) in spreads.enumerated() {
            #expect(spread.lowerBound == margin + CGFloat(2 * k) * pitch)
        }
        #expect(spreads[0].upperBound == geometry.textFrame(at: 0).maxX, "a spread is a text card")
        #expect(spreads.last?.upperBound == geometry.mediaFrame(at: 8).maxX, "the odd column ends the row")

        let offsets: ClosedRange<CGFloat> = 0...(geometry.contentSize.width - width)
        func snap(_ projected: CGFloat, _ direction: RowEdgeSnap.Direction?) -> CGFloat {
            RowEdgeSnap.target(
                projected: projected, direction: direction, items: spreads,
                viewport: width, margin: margin, offsets: offsets
            )
        }
        // Forward from the start: the second spread (columns 2–3, text card
        // 1) comes flush right — two whole media, one whole text card.
        let forward = snap(30, .forward)
        #expect(forward == spreads[1].upperBound + margin - width)
        #expect(geometry.textFrame(at: 1).maxX - forward == width - margin)
        // Back from there: the start, flush left.
        #expect(snap(forward - 30, .backward) == 0)
        // Back from further on: a spread's leading edge on the left margin,
        // which is a text card's and an even column's.
        let far = snap(spreads[3].upperBound - width + 40, .forward)
        let back = snap(far - 30, .backward)
        #expect(spreads.contains { $0.lowerBound - margin == back })
        // Every rest is a spread flush with a margin, or an end.
        let anchors = spreads.flatMap { [$0.lowerBound - margin, $0.upperBound + margin - width] }
            + [offsets.lowerBound, offsets.upperBound]
        for rest in [forward, far, back] {
            #expect(anchors.contains(rest), "\(rest) is off the grid")
        }
        #expect(snap(offsets.upperBound + 200, .forward) == offsets.upperBound)
        #expect(snap(-50, .backward) == 0)
    }

    /// No text card: the row snaps by column, exactly as the single lane.
    @Test func withoutTextTheRowSnapsByColumn() {
        let geometry = Lanes.geometry(forWidth: 402, mediaCount: 6, textCount: 0)
        #expect(geometry.snapExtents == (0..<6).map { geometry.mediaFrame(at: $0) }.map { $0.minX...$0.maxX })
    }

    /// Through the row's own delegate: a forward flick from the start rests
    /// with the second text card flush right, a flick back returns to the
    /// start.
    @Test func theLanesSnapThroughTheirDelegate() throws {
        let fixture = Fixture(cards: Self.mixed, lanes: true)
        let row = try #require(fixture.cardsRow)
        let geometry = try #require(fixture.rails.debugLanesGeometry)

        var target = CGPoint(x: 40, y: 0)
        fixture.rails.scrollViewWillEndDragging(row, withVelocity: CGPoint(x: 1.5, y: 0), targetContentOffset: &target)
        #expect(geometry.textFrame(at: 1).maxX - target.x == row.bounds.width - Metrics.sideMargin)

        var back = CGPoint(x: target.x - 20, y: 0)
        fixture.rails.scrollViewWillEndDragging(row, withVelocity: CGPoint(x: -1.5, y: 0), targetContentOffset: &back)
        #expect(back.x == 0, "back to the start, flush left")
    }

    // MARK: - Heroes

    /// A card of either lane hands the flight its own rect — the cell where
    /// it rests, in the host's space.
    @Test(arguments: [GalleryPost.Kind.video, .text])
    func eitherLanesCardIsAHeroSource(kind: GalleryPost.Kind) throws {
        let cards = Self.mixed
        let fixture = Fixture(cards: cards, lanes: true)
        let index = try #require(cards.firstIndex { $0.kind == kind })
        let tapped = cards[index]
        let origin = ForYouRowOrigins.card(
            tapped, stream: cards, rails: fixture.rails, page: fixture.page, host: fixture.host.view
        )
        let cell = try #require(fixture.rails.debugCardCell(at: index))
        let frame = try #require(origin.frame(fixture.host.view))

        #expect(frame == cell.convert(cell.bounds, to: fixture.host.view))
        #expect(origin.hasHero == (kind != .text))
        let reveal = try #require(origin.textReveal)
        #expect(reveal.rowFrame(fixture.host.view) == frame)
        let standIn = try #require(reveal.makeDismissStandIn(nil))
        #expect(standIn.bounds.size == frame.size, "the close lands as the lane's own card")
    }

    /// A card scrolled away under the open post is brought back before the
    /// close measures — in either lane, wholly in view, the row resting on a
    /// spread.
    @Test(arguments: [GalleryPost.Kind.photo, .text])
    func aCardScrolledAwayComesBackOnASpread(kind: GalleryPost.Kind) throws {
        let cards = Self.mixed
        let fixture = Fixture(cards: cards, lanes: true)
        let row = try #require(fixture.cardsRow)
        let geometry = try #require(fixture.rails.debugLanesGeometry)
        // The LAST card of its lane, from the start: off to the right.
        let index = try #require(cards.lastIndex { ($0.kind == .text) == (kind == .text) })
        let origin = ForYouRowOrigins.card(
            cards[index], stream: cards, rails: fixture.rails, page: fixture.page, host: fixture.host.view
        )
        #expect(origin.frame(fixture.host.view) == nil, "precondition: the card is out of the row")

        origin.willStageDismissal()

        let landed = try #require(origin.frame(fixture.host.view))
        let rails = fixture.rails.convert(fixture.rails.bounds, to: fixture.host.view)
        #expect(rails.minX + Metrics.sideMargin <= landed.minX + 0.5)
        #expect(landed.maxX <= rails.maxX - Metrics.sideMargin + 0.5, "\(landed) is not wholly in view")
        let offset = row.contentOffset.x
        let onSpread = geometry.snapExtents.contains {
            $0.upperBound + Metrics.sideMargin - row.bounds.width == offset
                || $0.lowerBound - Metrics.sideMargin == offset
        }
        #expect(onSpread || offset == row.contentSize.width - row.bounds.width, "rest \(offset) is off the grid")

        // And back to the first card, scrolled away the other way.
        let first = try #require(cards.firstIndex { ($0.kind == .text) == (kind == .text) })
        let back = ForYouRowOrigins.card(
            cards[first], stream: cards, rails: fixture.rails, page: fixture.page, host: fixture.host.view
        )
        back.willStageDismissal()
        #expect(row.contentOffset.x == 0, "the first card returns flush left, at the start")
    }

    /// The long press lifts a text card's preview too.
    @Test func aTextCardLiftsAPreview() throws {
        let cards = Self.mixed
        let fixture = Fixture(cards: cards, lanes: true)
        let index = try #require(cards.firstIndex { $0.kind == .text })
        let configuration = try #require(fixture.rails.debugCardMenuConfiguration(at: index))
        var opened: [Int] = []
        fixture.rails.onCardTapped = { opened.append($0) }
        fixture.rails.debugCommitPreview(configuration)
        #expect(opened == [index])
    }

    // MARK: - Fixtures

    /// Seven media and three text posts, interleaved as a row might hold them.
    private static let mixed: [GalleryPost] = [
        post("m0", kind: .video), post("t0", kind: .text), post("m1", kind: .photo),
        post("m2", kind: .video), post("t1", kind: .text), post("m3", kind: .photo),
        post("m4", kind: .photo), post("m5", kind: .video), post("t2", kind: .text),
        post("m6", kind: .photo)
    ]

    private static func post(_ id: String, kind: GalleryPost.Kind, caption: String? = nil) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(id).jpg"),
            caption: caption ?? "caption \(id)", publishedAtMS: 1,
            authorID: ProfileID("bo"), authorName: "Bo", authorHandle: "bo"
        )
    }

    private static func overlay(in cell: UICollectionViewCell) -> ForYouCardCaptionOverlay? {
        cell.contentView.subviews.compactMap { $0 as? ForYouCardCaptionOverlay }.first
    }

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// The rows in a real window, laid out, over the list page they lead.
    @MainActor
    private final class Fixture {
        let window: UIWindow
        let host = UIViewController()
        let rails: ForYouRailsView
        let page: ForYouGridPage

        init(cards: [GalleryPost], lanes: Bool, width: CGFloat = 402) {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 874))
            let pipeline = ImagePipeline(fetcher: SilentFetcher())
            rails = ForYouRailsView(imagePipeline: pipeline, videoPlayback: nil, followingLanes: lanes)
            page = ForYouGridPage(imagePipeline: pipeline, style: .discover, videoPlayback: nil)
            var model = ForYouViewModel.Rails()
            model.following = cards
            rails.render(model)
            window.rootViewController = host
            window.isHidden = false
            page.frame = host.view.bounds
            host.view.addSubview(page)
            rails.frame = CGRect(x: 0, y: 120, width: width, height: rails.preferredHeight(forWidth: width))
            host.view.addSubview(rails)
            window.layoutIfNeeded()
            rails.layoutIfNeeded()
            for row in rails.subviews.compactMap({ $0 as? UICollectionView }) { row.layoutIfNeeded() }
        }

        /// The Following row — the second of the rows' two scroll views.
        var cardsRow: UICollectionView? {
            rails.subviews.compactMap { $0 as? UICollectionView }.last
        }
    }
}
