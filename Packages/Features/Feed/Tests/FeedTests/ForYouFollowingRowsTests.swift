import CoreModels
import CoreStorage
import DesignSystem
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The Following section as TWO INDEPENDENT ROWS (the user's call, 3 October
/// 2026): media cards in one horizontal scroller, text posts as the LIST's own
/// card — two media cards wide, two lines of caption, its repost, save,
/// comments and staking like — in another, under one heading.
@MainActor
struct ForYouFollowingRowsTests {
    private typealias Metrics = ForYouRailsView.Metrics
    private typealias Rows = ForYouFollowingRows

    // MARK: - Two scroll views

    /// Three scrollers: the Friends row, the media row and the text row —
    /// each Following row its own collection view holding only its kind.
    @Test func followingIsTwoScrollViews() throws {
        let fixture = Fixture(cards: Self.mixed)
        let rows = fixture.rails.subviews.compactMap { $0 as? UICollectionView }
        #expect(rows.count == 3, "Friends, Following media, Following text")
        #expect(fixture.mediaRow !== fixture.textRow)
        #expect(!fixture.mediaRow.isHidden && !fixture.textRow.isHidden)
        for row in [fixture.mediaRow, fixture.textRow] {
            #expect(row.numberOfSections == 1)
            #expect(row.collectionViewLayout is UICollectionViewFlowLayout)
        }
        #expect(fixture.mediaRow.numberOfItems(inSection: 0) == Self.mixed.filter { $0.kind != .text }.count)
        #expect(fixture.textRow.numberOfItems(inSection: 0) == Self.mixed.filter { $0.kind == .text }.count)
        #expect(fixture.mediaRow.visibleCells.allSatisfy { $0 is ForYouFollowingCardCell })
        #expect(fixture.textRow.visibleCells.allSatisfy { $0 is PostGridListRowCell })
    }

    /// Media go to the media row and words to the text row, each in the
    /// section's order (unseen first); a tap still opens the post it shows.
    @Test func mediaOnTopTextBelowEachInOrder() throws {
        let cards = Self.mixed
        let fixture = Fixture(cards: cards)
        let media = cards.filter { $0.kind != .text }.map(\.id)
        let text = cards.filter { $0.kind == .text }.map(\.id)
        #expect(Rows.partition(cards).media.map(\.id) == media)
        #expect(Rows.partition(cards).text.map(\.id) == text)
        for (index, post) in cards.enumerated() {
            let place = try #require(fixture.rails.debugCardPlace(at: index))
            let isText = post.kind == .text
            #expect(place.row === (isText ? fixture.textRow : fixture.mediaRow))
            #expect(place.indexPath.item == (isText ? text : media).firstIndex(of: post.id))
        }
        #expect(ForYouRailsView.height(
            forWidth: 402, friends: 0, following: cards.count, textCards: text.count
        ) == fixture.rails.preferredHeight(forWidth: 402))

        var opened: [Int] = []
        fixture.rails.onCardTapped = { opened.append($0) }
        let firstText = try #require(cards.firstIndex { $0.kind == .text })
        let firstMedia = try #require(cards.firstIndex { $0.kind != .text })
        #expect(fixture.rails.debugTapCard(at: firstText))
        #expect(fixture.rails.debugTapCard(at: firstMedia))
        #expect(opened == [firstText, firstMedia], "each row opens its own post")
    }

    // MARK: - The geometry

    /// The media row is the Following cards at 2.3 per width; the text row,
    /// under it and the gap, is text cards two media cards and their gap
    /// wide, one after the other — and both rows' second item starts at the
    /// same x, so they peek alike.
    @Test(arguments: [375, 402, 440] as [CGFloat])
    func eachRowLaysOutItsOwnCards(width: CGFloat) throws {
        let cards = Self.mixed
        let fixture = Fixture(cards: cards, width: width)
        let card = Metrics.cardSize(forWidth: width)
        let gap = Metrics.itemGap
        let margin = Metrics.sideMargin
        let text = Rows.textCardSize(forWidth: width)
        #expect(text.width == card.width * 2 + gap)
        #expect(text.height == Rows.textCardHeight(forWidth: width))

        let media = cards.indices.filter { cards[$0].kind != .text }
        let words = cards.indices.filter { cards[$0].kind == .text }
        for (column, index) in media.enumerated() {
            let frame = try #require(fixture.rails.debugCardLayoutFrame(at: index))
            #expect(frame.size == card)
            #expect(frame.minX == margin + CGFloat(column) * (card.width + gap))
        }
        for (position, index) in words.enumerated() {
            let frame = try #require(fixture.rails.debugCardLayoutFrame(at: index))
            #expect(frame.size == text)
            #expect(frame.minX == margin + CGFloat(position) * (text.width + gap))
        }
        // The peek: the text row's second card starts where the media row's
        // third does.
        let thirdMedia = try #require(fixture.rails.debugCardLayoutFrame(at: media[2]))
        let secondText = try #require(fixture.rails.debugCardLayoutFrame(at: words[1]))
        #expect(thirdMedia.minX == secondText.minX)

        // Stacked: the media row, the gap, the text row.
        #expect(fixture.mediaRow.frame.height == card.height)
        #expect(fixture.textRow.frame.height == text.height)
        #expect(fixture.textRow.frame.minY == fixture.mediaRow.frame.maxY + Rows.rowGap)
        #expect(fixture.mediaRow.frame.width == width && fixture.textRow.frame.width == width)
        // Each as wide as its OWN items.
        #expect(fixture.mediaRow.contentSize.width
            == margin * 2 + CGFloat(media.count) * (card.width + gap) - gap)
        #expect(fixture.textRow.contentSize.width
            == margin * 2 + CGFloat(words.count) * (text.width + gap) - gap)
    }

    // MARK: - Independent

    /// ⚠️ THE USER'S ASK: scrolling the media cards does not move the text
    /// cards, and the other way round.
    @Test func scrollingOneRowLeavesTheOtherWhereItWas() throws {
        let fixture = Fixture(cards: Self.mixed)
        let media = fixture.mediaRow, text = fixture.textRow

        media.setContentOffset(CGPoint(x: 200, y: 0), animated: false)
        fixture.rails.scrollViewDidScroll(media)
        #expect(media.contentOffset.x == 200)
        #expect(text.contentOffset.x == 0, "the text row moved with the media row")

        text.setContentOffset(CGPoint(x: 150, y: 0), animated: false)
        fixture.rails.scrollViewDidScroll(text)
        #expect(text.contentOffset.x == 150)
        #expect(media.contentOffset.x == 200, "the media row moved with the text row")

        // A release in one row bends only its own deceleration.
        fixture.rails.scrollViewWillBeginDragging(media)
        var target = CGPoint(x: 260, y: 0)
        fixture.rails.scrollViewWillEndDragging(media, withVelocity: CGPoint(x: 1.5, y: 0), targetContentOffset: &target)
        #expect(text.contentOffset.x == 150)
    }

    // MARK: - A row with nothing in it

    /// No text posts: no text row — the section is the heading and the media
    /// row, one card tall.
    @Test func withoutTextThereIsNoTextRow() throws {
        let cards = Self.mixed.filter { $0.kind != .text }
        let fixture = Fixture(cards: cards)
        let card = Metrics.cardSize(forWidth: 402)
        #expect(fixture.textRow.isHidden)
        #expect(!fixture.mediaRow.isHidden)
        #expect(fixture.mediaRow.bounds.height == card.height)
        #expect(Rows.height(forWidth: 402, media: cards.count, text: 0) == card.height)
        #expect(ForYouRailsView.height(forWidth: 402, friends: 0, following: cards.count)
            == fixture.rails.preferredHeight(forWidth: 402))
        #expect(!fixture.followingHeader.isHidden, "the heading stays")
        #expect(fixture.mediaRow.frame.minY == fixture.followingHeader.frame.maxY)
    }

    /// No media posts: no media row — the text row sits under the heading.
    @Test func withoutMediaThereIsNoMediaRow() throws {
        let cards = Self.mixed.filter { $0.kind == .text }
        let fixture = Fixture(cards: cards)
        #expect(fixture.mediaRow.isHidden)
        #expect(!fixture.textRow.isHidden)
        #expect(!fixture.followingHeader.isHidden, "the heading stays")
        #expect(fixture.textRow.frame.minY == fixture.followingHeader.frame.maxY)
        #expect(Rows.height(forWidth: 402, media: 0, text: cards.count) == Rows.textCardHeight(forWidth: 402))
        #expect(ForYouRailsView.height(forWidth: 402, friends: 0, following: cards.count, textCards: cards.count)
            == fixture.rails.preferredHeight(forWidth: 402))
    }

    /// Both rows: their heights and the gap between them.
    @Test func bothRowsStackWithTheGap() {
        let card = Metrics.cardSize(forWidth: 402)
        #expect(Rows.height(forWidth: 402, media: 4, text: 3)
            == card.height + Rows.rowGap + Rows.textCardHeight(forWidth: 402))
        #expect(Rows.height(forWidth: 402, media: 0, text: 0) == 0)
    }

    // MARK: - The text card is the list's card

    /// ⚠️ THE TEXT CARD IS THE CLASSIC CARD (the user's call, 3 October
    /// 2026): the list's own cell — author band, caption, closing line with
    /// repost and save — held to two lines with an ellipsis and no "Show
    /// more", at the text row's size, on the list card's own curve.
    @Test(arguments: [375, 402, 440] as [CGFloat])
    func aTextCardIsTheListsCard(width: CGFloat) throws {
        let long = String(repeating: "A long post that goes on and on. ", count: 12)
        let cards = [Self.post("m0", kind: .photo), Self.post("t0", kind: .text, caption: long)]
        let fixture = Fixture(cards: cards, width: width)
        let cell = try #require(fixture.rails.debugTextCardCell(at: 1))
        cell.layoutIfNeeded()
        #expect(fixture.rails.debugCardCell(at: 1) == nil, "no Following card draws words any more")

        #expect(cell.fixedCaptionLines == Rows.textLines)
        #expect(Rows.textLines == 2)
        #expect(cell.debugCaptionLineLimit == 2)
        #expect(cell.debugCaptionLineBreakMode == .byTruncatingTail)
        #expect(!cell.debugShowsMoreAffordance)
        #expect(cell.debugCaptionText == long, "the label cuts the words; they are all there")
        let line = UIFont.preferredFont(forTextStyle: .body).lineHeight
        #expect(cell.debugCaptionFrame.height > line * 1.5, "two lines, not one")
        #expect(cell.debugCaptionFrame.height < line * 2.6, "two lines, not more")

        // The band names the author; the closing line holds repost and save.
        #expect(cell.authorBandModel?.name == "Bo")
        #expect(cell.visibleRowActions.repost)
        #expect(cell.visibleRowActions.bookmark)
        // Everything on the card, the closing line at its foot.
        let closing = cell.debugClosingLineFrame
        #expect(!closing.isNull)
        #expect(abs(closing.maxY - (cell.bounds.height - PostGridListRowCell.metaBottomInset)) < 0.5)
        #expect(cell.debugCaptionFrame.maxY <= closing.minY)

        // Two media cards and their gap wide, the height the list's card
        // needs for its two lines at that width.
        let card = Metrics.cardSize(forWidth: width)
        #expect(cell.bounds.width == card.width * 2 + Metrics.itemGap)
        #expect(cell.bounds.height == PostGridListRowCell.fixedTextCardHeight(
            width: cell.bounds.width, captionLines: 2
        ))
    }

    /// A short caption keeps the card's size and its closing line where a
    /// long one puts it — the row is one height.
    @Test func aShortCaptionKeepsTheRowsShape() throws {
        let cards = [
            Self.post("t0", kind: .text, caption: String(repeating: "Long words here. ", count: 20)),
            Self.post("t1", kind: .text, caption: "Short.")
        ]
        let fixture = Fixture(cards: cards)
        let long = try #require(fixture.rails.debugTextCardCell(at: 0))
        let short = try #require(fixture.rails.debugTextCardCell(at: 1))
        for cell in [long, short] { cell.layoutIfNeeded() }
        #expect(long.bounds.size == short.bounds.size)
        #expect(long.debugClosingLineFrame == short.debugClosingLineFrame)
    }

    // MARK: - Its controls

    /// ⚠️ THE LIKE IS THE REAL STAKE, not the compact cards' readout: a tap
    /// on the chip spends from the wallet and the heart turns red.
    @Test func aTextCardsLikeStakes() throws {
        let wallet = Self.wallet()
        let before = wallet.balance
        let fixture = Fixture(cards: Self.mixed, staking: PostCardStaking(wallet: wallet))
        let index = try #require(Self.mixed.firstIndex { $0.kind == .text })
        let cell = try #require(fixture.rails.debugTextCardCell(at: index))
        let id = Self.mixed[index].id

        #expect(cell.debugTapLikesChip(), "the chip is wired")
        #expect(wallet.balance == before - WalletStore.Policy.defaultStakeAmount)
        #expect(wallet.boostTotal(forTarget: id.rawValue) == WalletStore.Policy.defaultStakeAmount)
        #expect(fixture.rails.cardStake(for: Self.mixed[index]) == WalletStore.Policy.defaultStakeAmount)
    }

    /// The comment count opens the card's post, as a tap on the card does.
    @Test func aTextCardsCommentsOpenItsPost() throws {
        let fixture = Fixture(cards: Self.mixed)
        var opened: [Int] = []
        fixture.rails.onCardTapped = { opened.append($0) }
        let index = try #require(Self.mixed.firstIndex { $0.kind == .text })
        let cell = try #require(fixture.rails.debugTextCardCell(at: index))
        #expect(cell.debugTapCommentsChip())
        #expect(opened == [index])
    }

    // MARK: - Snapping, per row

    /// Every offset `row` may rest at: an item flush with a margin (its
    /// leading edge on the left one, or its trailing edge on the right one),
    /// or an end.
    private func anchors(of row: UICollectionView) -> [CGFloat] {
        let width = row.bounds.width, margin = Metrics.sideMargin
        let high = row.contentSize.width - width
        let frames = (0..<row.numberOfItems(inSection: 0)).compactMap {
            row.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
        }
        return frames.flatMap { [$0.minX - margin, $0.maxX + margin - width] }
            .map { min(max($0, 0), high) } + [0, high]
    }

    /// The media row rests per MEDIA CARD, the gesture picking the edge — a
    /// forward flick from the start leaves a card flush right and nothing
    /// beyond it; back returns to the start, flush left.
    @Test func theMediaRowSnapsPerCard() throws {
        let fixture = Fixture(cards: Self.mixed)
        let row = fixture.mediaRow
        var target = CGPoint(x: 40, y: 0)
        fixture.rails.scrollViewWillEndDragging(row, withVelocity: CGPoint(x: 1.5, y: 0), targetContentOffset: &target)
        let frames = (0..<row.numberOfItems(inSection: 0)).compactMap {
            row.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
        }
        let flushRight = try #require(frames.first { $0.maxX - target.x == row.bounds.width - Metrics.sideMargin })
        let next = try #require(frames.first { $0.minX > flushRight.maxX })
        #expect(next.minX - target.x >= row.bounds.width, "nothing to the right of the snapped card")
        #expect(flushRight.width == Metrics.cardSize(forWidth: 402).width, "a media card, not a pair")

        var back = CGPoint(x: target.x - 20, y: 0)
        fixture.rails.scrollViewWillEndDragging(row, withVelocity: CGPoint(x: -1.5, y: 0), targetContentOffset: &back)
        #expect(back.x == 0, "back to the start, flush left")
    }

    /// The text row rests per TEXT CARD by the same rule, ONE card per
    /// gesture however hard the fling: forward from the start, card 1 flush
    /// right (card 0 peeking left, nothing right); forward again, card 2;
    /// back, card 1 flush LEFT; the first card is flush left at the start and
    /// the last flush right at the end.
    @Test(arguments: [375, 402, 440] as [CGFloat])
    func theTextRowSnapsPerTextCardOneAtATime(width: CGFloat) throws {
        let cards = (0..<5).map { Self.post("t\($0)", kind: .text) }
        let fixture = Fixture(cards: cards, width: width)
        let row = fixture.textRow
        let margin = Metrics.sideMargin
        let frames = (0..<5).compactMap { row.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
        #expect(frames.count == 5)
        let end = row.contentSize.width - width

        // A FLING from the start whose projection would cross three cards.
        var target = CGPoint(x: frames[3].maxX, y: 0)
        fixture.rails.scrollViewWillBeginDragging(row)
        row.contentOffset.x = 30
        fixture.rails.scrollViewDidScroll(row)
        fixture.rails.scrollViewWillEndDragging(row, withVelocity: CGPoint(x: 4, y: 0), targetContentOffset: &target)
        #expect(target.x == frames[1].maxX + margin - width, "one card per gesture: card 1 flush right")
        #expect(frames[2].minX - target.x >= width, "nothing to the right of it")
        #expect(frames[0].maxX - target.x > 0, "card 0 peeks on the left")

        // Forward again, from that rest: card 2.
        row.contentOffset.x = target.x
        fixture.rails.scrollViewWillBeginDragging(row)
        row.contentOffset.x = target.x + 20
        fixture.rails.scrollViewDidScroll(row)
        var next = CGPoint(x: target.x + 20, y: 0)
        fixture.rails.scrollViewWillEndDragging(row, withVelocity: CGPoint(x: 1, y: 0), targetContentOffset: &next)
        #expect(next.x == frames[2].maxX + margin - width)

        // Back from there: card 1's LEADING edge on the left margin.
        row.contentOffset.x = next.x
        fixture.rails.scrollViewWillBeginDragging(row)
        row.contentOffset.x = next.x - 20
        fixture.rails.scrollViewDidScroll(row)
        var back = CGPoint(x: 0, y: 0)
        fixture.rails.scrollViewWillEndDragging(row, withVelocity: CGPoint(x: -4, y: 0), targetContentOffset: &back)
        #expect(back.x == frames[1].minX - margin, "one card back, flush left — not all the way home")

        // The ends: the first card flush left, the last flush right.
        row.contentOffset.x = 0
        #expect(fixture.rails.snapTarget(in: row, projected: 0, start: 0, direction: nil) == 0)
        #expect(frames[0].minX - margin == 0)
        #expect(frames[4].maxX + margin - width == end, "the last card ends flush right")
        row.contentOffset.x = end - 1
        let atEnd = fixture.rails.snapTarget(in: row, projected: end, start: end - 1, direction: .forward)
        #expect(atEnd == end)

        // A release with no speed goes by the drag's last movement — still
        // one card, and still a card's edge.
        row.contentOffset.x = 60
        let slow = fixture.rails.snapTarget(in: row, projected: 60, start: 0, direction: .forward)
        #expect(slow == frames[1].maxX + margin - width)
        #expect(anchors(of: row).contains(slow))
    }

    // MARK: - Heroes

    /// A card of either row hands the flight its own rect — the cell where
    /// it rests, in the host's space.
    @Test(arguments: [GalleryPost.Kind.video, .text])
    func eitherRowsCardIsAHeroSource(kind: GalleryPost.Kind) throws {
        let cards = Self.mixed
        let fixture = Fixture(cards: cards)
        let index = try #require(cards.firstIndex { $0.kind == kind })
        let tapped = cards[index]
        let origin = ForYouRowOrigins.card(
            tapped, stream: cards, rails: fixture.rails, page: fixture.page, host: fixture.host.view
        )
        let cell: UICollectionViewCell = try #require(
            kind == .text ? fixture.rails.debugTextCardCell(at: index) : fixture.rails.debugCardCell(at: index)
        )
        let frame = try #require(origin.frame(fixture.host.view))

        #expect(frame == cell.convert(cell.bounds, to: fixture.host.view))
        #expect(origin.hasHero == (kind != .text))
        let reveal = try #require(origin.textReveal)
        #expect(reveal.rowFrame(fixture.host.view) == frame)
        let standIn = try #require(reveal.makeDismissStandIn(nil))
        standIn.frame = CGRect(origin: .zero, size: frame.size)
        standIn.layoutIfNeeded()
        if kind == .text {
            // The list's stand-in, drawing the text row's card.
            #expect(standIn is RevealDismissCardView)
            let card = try #require(standIn.subviews.first as? PostGridListRowCell)
            #expect(card.bounds.size == frame.size, "the close lands as the row's own card")
        } else {
            #expect(standIn.bounds.size == frame.size, "the close lands as the row's own card")
        }
    }

    /// ⚠️ A TEXT CARD OPENS THE WAY DISCOVER'S LIST OPENS ITS TEXT CARDS: the
    /// page aligned to the card's caption, the card's band borrowed for the
    /// flight, the page veiled below the card's two lines, on the list card's
    /// own corner and fill — and it never flies or wears a furniture copy.
    @Test func aTextCardOpensAsTheListsWindow() throws {
        let long = String(repeating: "A long post that goes on and on. ", count: 12)
        let cards = [Self.post("m0", kind: .photo), Self.post("t0", kind: .text, caption: long)]
        let fixture = Fixture(cards: cards)
        let cell = try #require(fixture.rails.debugTextCardCell(at: 1))
        cell.layoutIfNeeded()
        let origin = ForYouRowOrigins.card(
            cards[1], stream: cards, rails: fixture.rails, page: fixture.page, host: fixture.host.view
        )
        let reveal = try #require(origin.textReveal)

        #expect(!origin.hasHero)
        #expect(origin.restingOverlay == nil, "a text card never flies, so it wears no copy")
        #expect(reveal.alignsPageToSource, "the page grows out of the card, caption on caption")
        #expect(reveal.captionTop == cell.revealCaptionTop)
        #expect(reveal.captionTop > 0, "under the band")
        #expect(reveal.captionEnd == cell.revealCut)
        #expect(reveal.captionEnd.map { $0 < cell.bounds.height - cell.revealCaptionTop } == true,
                "a cut caption veils the page below its two lines")
        #expect(reveal.authorBand == cell.authorBandModel)
        #expect(reveal.cornerRadius == nil, "the card's own curve")
        #expect(reveal.fill == PostGridListRowCell.cardFillColor)

        // The stand-in is the card, line for line.
        let standIn = try #require(reveal.makeDismissStandIn(nil))
        standIn.frame = cell.bounds
        standIn.layoutIfNeeded()
        let card = try #require(standIn.subviews.first as? PostGridListRowCell)
        #expect(card.fixedCaptionLines == 2)
        #expect(card.debugCaptionFrame == cell.debugCaptionFrame)
        #expect(card.debugClosingLineFrame == cell.debugClosingLineFrame)
        #expect(card.visibleRowActions.repost && card.visibleRowActions.bookmark)

        // The opening hides the card under its window; the close puts it back.
        reveal.setConcealed(true)
        #expect(cell.isHidden)
        reveal.setConcealed(false)
        #expect(!cell.isHidden)
    }

    /// A card scrolled away under the open post is brought back before the
    /// close measures — in ITS row, wholly in view, on one of that row's
    /// rests — and the OTHER row stays where the viewer left it.
    @Test(arguments: [GalleryPost.Kind.photo, .text])
    func aCardScrolledAwayComesBackInItsOwnRow(kind: GalleryPost.Kind) throws {
        let cards = Self.mixed
        let fixture = Fixture(cards: cards)
        let isText = kind == .text
        let row = isText ? fixture.textRow : fixture.mediaRow
        let other = isText ? fixture.mediaRow : fixture.textRow
        other.contentOffset.x = 37
        // The LAST card of its row, from the start: off to the right.
        let index = try #require(cards.lastIndex { ($0.kind == .text) == isText })
        let origin = ForYouRowOrigins.card(
            cards[index], stream: cards, rails: fixture.rails, page: fixture.page, host: fixture.host.view
        )
        #expect(origin.frame(fixture.host.view) == nil, "precondition: the card is out of the row")

        origin.willStageDismissal()

        let landed = try #require(origin.frame(fixture.host.view))
        let rails = fixture.rails.convert(fixture.rails.bounds, to: fixture.host.view)
        #expect(rails.minX + Metrics.sideMargin <= landed.minX + 0.5)
        #expect(landed.maxX <= rails.maxX - Metrics.sideMargin + 0.5, "\(landed) is not wholly in view")
        #expect(anchors(of: row).contains(row.contentOffset.x), "rest \(row.contentOffset.x) is off its row's rests")
        #expect(other.contentOffset.x == 37, "the other row was moved")

        // And back to the first card, scrolled away the other way.
        let first = try #require(cards.firstIndex { ($0.kind == .text) == isText })
        let back = ForYouRowOrigins.card(
            cards[first], stream: cards, rails: fixture.rails, page: fixture.page, host: fixture.host.view
        )
        back.willStageDismissal()
        #expect(row.contentOffset.x == 0, "the first card returns flush left, at the start")
        #expect(other.contentOffset.x == 37)
    }

    /// The long press lifts a preview from either row — committed into the
    /// card's own open.
    @Test(arguments: [GalleryPost.Kind.photo, .text])
    func eitherRowsCardLiftsAPreview(kind: GalleryPost.Kind) throws {
        let cards = Self.mixed
        let fixture = Fixture(cards: cards)
        let index = try #require(cards.firstIndex { $0.kind == kind })
        let configuration = try #require(fixture.rails.debugCardMenuConfiguration(at: index))
        var opened: [Int] = []
        fixture.rails.onCardTapped = { opened.append($0) }
        fixture.rails.debugCommitPreview(configuration)
        #expect(opened == [index])
    }

    // MARK: - Fixtures

    /// Seven media and three text posts, interleaved as the section might
    /// hold them.
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
            authorID: ProfileID("bo"), authorName: "Bo", authorHandle: "bo",
            // A count, so every card wears its heart as the mock's do.
            reactionCount: 234, commentCount: 5
        )
    }

    private static func wallet() -> WalletStore {
        let name = "foryou-rows-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return WalletStore(defaults: defaults)
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

        init(cards: [GalleryPost], width: CGFloat = 402, staking: PostCardStaking? = nil) {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 874))
            let pipeline = ImagePipeline(fetcher: SilentFetcher())
            rails = ForYouRailsView(imagePipeline: pipeline, videoPlayback: nil)
            rails.staking = staking
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

        var mediaRow: UICollectionView { rails.debugMediaRow }
        var textRow: UICollectionView { rails.debugTextRow }
        /// "Following" — the second of the rows' headings.
        var followingHeader: SectionTitleView { rails.debugHeaders[1] }
    }
}
