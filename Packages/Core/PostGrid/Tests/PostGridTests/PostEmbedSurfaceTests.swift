import CoreModels
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A channel's showcase on the grid's surfaces (#2216, part 2): each keeps
/// its text face and draws the caption's place as the embed card, at its
/// room's size — full on a list card and a history row (the author's words
/// above it), compact on a shelf's fixed card and the mark on a tile (the
/// card alone) — and none of it with the switch off.
@MainActor
struct PostEmbedSurfaceTests {
    private let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    private static let channel = ChannelEmbed(
        conversationID: ConversationID("ch-harbour"), name: "Harbour notes", description: "Boats in, boats out.",
        subscriberCount: 12_400, visibility: .public, viewerState: .none, availability: .available,
        lastMessagePreview: "The ferry's late again"
    )

    private func post(
        caption: String = "Boats in at six", embed: PostEmbed? = .channel(channel), kind: GalleryPost.Kind = .text,
        voice: PostVoice? = nil
    ) -> GalleryPost {
        var post = GalleryPost(
            id: PostID("p-showcase"), kind: kind, isRepost: false, thumbnailURL: nil,
            caption: caption, publishedAtMS: 1_800_000_000_000,
            authorID: ProfileID("a1"), authorName: "Ava Moreau", authorHandle: "ava", reactionCount: 12
        )
        post.embed = embed
        post.voice = voice
        return post
    }

    private func listCard(_ post: GalleryPost, captionLines: Int? = nil, showsEmbed: Bool = true) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 360, height: 320))
        cell.configure(with: post, imagePipeline: pipeline, captionLines: captionLines, showsVoice: true, showsEmbed: showsEmbed)
        // Sized as a list sizes it, so every part — the card's button
        // included — lies inside the cell a hit test starts from.
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.frame.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
        return cell
    }

    // MARK: - Sizes

    @Test func eachSurfacePicksItsSize() {
        let showcase = post()
        #expect(PostGridListRowCell.embedSize(for: showcase, captionLines: nil, showsEmbed: true) == .full)
        #expect(PostGridListRowCell.embedSize(for: showcase, captionLines: 2, showsEmbed: true) == .compact,
                "a shelf's fixed card is compact")
        #expect(PostGridTileCell.embedSize(for: showcase, showsEmbed: true) == .mark)
        #expect(PostHistoryRowCell.embedSize(for: showcase, showsEmbed: true) == .full)
    }

    @Test func noSurfaceDrawsACardWithTheSwitchOffOrWithoutOne() {
        for candidate in [post(embed: nil), post(kind: .photo)] {
            #expect(PostGridListRowCell.embedSize(for: candidate, captionLines: nil, showsEmbed: true) == nil)
            #expect(PostGridTileCell.embedSize(for: candidate, showsEmbed: true) == nil)
            #expect(PostHistoryRowCell.embedSize(for: candidate, showsEmbed: true) == nil)
        }
        #expect(PostGridListRowCell.embedSize(for: post(), captionLines: nil, showsEmbed: false) == nil)
        #expect(PostGridTileCell.embedSize(for: post(), showsEmbed: false) == nil)
        #expect(PostHistoryRowCell.embedSize(for: post(), showsEmbed: false) == nil)
    }

    // MARK: - The list's card

    @Test func aListCardDrawsTheCardFullUnderTheWords() throws {
        let cell = listCard(post())
        let card = try #require(cell.debugEmbedCard)
        #expect(card.size == .full)
        #expect(card.debugActionTitle == "Join")
        #expect(card.debugDescriptionText == "Boats in, boats out.")
        #expect(cell.debugCaptionText == "Boats in at six", "the author's words above a full card went")
        let cardFrame = card.convert(card.bounds, to: cell)
        #expect(cardFrame.minY >= cell.debugCaptionFrame.maxY, "the card isn't under the words")
    }

    @Test func aShelfCardDrawsTheCardCompactAndAlone() throws {
        let cell = listCard(post(), captionLines: 2)
        let card = try #require(cell.debugEmbedCard)
        #expect(card.size == .compact)
        #expect(card.debugActionTitle == "Join", "a compact card keeps the main action")
        #expect(card.debugDescriptionText == nil)
        #expect(cell.debugCaptionText?.isEmpty ?? true, "a compact card keeps no words")
    }

    /// A showcase takes no comments (#2216), so its card draws no comment
    /// count, whatever the post carries — seen on a profile's list card
    /// ("130") on the simulator.
    @Test func aShowcasesCardDrawsNoCommentCount() {
        var showcase = post()
        showcase.commentCount = 130
        #expect(!listCard(showcase).debugShowsCommentCount)
        var plain = post(embed: nil)
        plain.commentCount = 130
        #expect(listCard(plain).debugShowsCommentCount)
        // A count refresh keeps it away.
        let cell = listCard(showcase)
        cell.updateCounts(from: showcase)
        #expect(!cell.debugShowsCommentCount)
    }

    @Test func theSwitchOffShowsTodaysCard() {
        let cell = listCard(post(), showsEmbed: false)
        #expect(cell.debugEmbedCard == nil)
        #expect(cell.debugCaptionText == "Boats in at six")
    }

    @Test func aCardOutranksAVoice() throws {
        let voice = PostVoice(assetID: "v", url: URL(fileURLWithPath: "/tmp/v.m4a"), duration: 12,
                              waveform: Array(repeating: 10, count: 100))
        let cell = listCard(post(voice: voice))
        #expect(cell.debugEmbedCard != nil)
        #expect(cell.debugVoiceCaption == nil, "a showcase drew its voice too")
    }

    /// The card's button keeps its touch; anywhere else on the card the
    /// touch is the card's — the collection view's selection opens the post.
    @Test func theButtonKeepsItsTouchAndTheRestStaysTheCards() throws {
        let cell = listCard(post())
        let card = try #require(cell.debugEmbedCard)
        let button = card.debugActionButton
        let onButton = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: cell)
        #expect(PostEmbedView.keepsTouch(on: cell.hitTest(onButton, with: nil)), "the button gave its tap to the card")
        // The card's top-left corner — its photo, its name: the card's.
        let onCard = card.convert(CGPoint(x: 4, y: 4), to: cell)
        #expect(!PostEmbedView.keepsTouch(on: cell.hitTest(onCard, with: nil)), "the card took the post's tap")
        // The words above it: the card's too.
        let onWords = CGPoint(x: cell.debugCaptionFrame.midX, y: cell.debugCaptionFrame.midY)
        #expect(!PostEmbedView.keepsTouch(on: cell.hitTest(onWords, with: nil)))
    }

    @Test func aReusedCardForgetsItsEmbed() throws {
        let cell = listCard(post())
        #expect(cell.debugEmbedCard != nil)
        cell.prepareForReuse()
        #expect(cell.debugEmbedCard == nil)
        cell.configure(with: post(embed: nil), imagePipeline: pipeline, showsEmbed: true)
        #expect(cell.debugEmbedCard == nil, "a reused card kept the last post's embed")
        #expect(cell.debugCaptionText == "Boats in at six")
    }

    // MARK: - The tile

    @Test func aTileWearsTheMarkAndTakesNoTouch() throws {
        let tile = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 160))
        tile.configure(with: post(), imagePipeline: pipeline, showsEmbed: true)
        let mark = try #require(tile.debugEmbedMark)
        #expect(mark.size == .mark)
        #expect(mark.debugNameText == "Harbour notes")
        #expect(mark.debugActionTitle == nil, "a mark has no button")
        #expect(!mark.isUserInteractionEnabled, "the mark takes the tile's tap")
        #expect(tile.accessibilityLabel == "Channel Harbour notes, 12.4K subscribers")

        let plain = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 160))
        plain.configure(with: post(), imagePipeline: pipeline, showsEmbed: false)
        #expect(plain.debugEmbedMark == nil, "the switch off drew a mark")

        tile.prepareForReuse()
        tile.configure(with: post(embed: nil), imagePipeline: pipeline, showsEmbed: true)
        #expect(tile.debugEmbedMark == nil, "a reused tile kept the last post's mark")
        #expect(tile.accessibilityLabel == nil)
    }

    // MARK: - The history row

    @Test func aHistoryRowDrawsTheCardUnderItsTitle() throws {
        let row = PostHistoryRowCell(frame: CGRect(x: 0, y: 0, width: 360, height: 72))
        row.configure(with: post(), viewedAt: nil, imagePipeline: nil, showsEmbed: true)
        let card = try #require(row.debugEmbedCard)
        #expect(card.size == .full)
        #expect(row.debugShowsTitle && row.debugTitle == "Boats in at six", "the words above a full card went")
        #expect(row.accessibilityLabel?.hasPrefix("Boats in at six, Channel Harbour notes, 12.4K subscribers") == true)
        #expect(row.accessibilityCustomActions?.contains { $0.name == "Join" } == true,
                "VoiceOver can't reach the card's action in a one-element row")

        row.prepareForReuse()
        #expect(row.debugEmbedCard == nil)
        row.configure(with: post(), viewedAt: nil, imagePipeline: nil, showsEmbed: false)
        #expect(row.debugEmbedCard == nil, "the switch off drew a card")
        #expect(row.debugShowsTitle && row.debugTitle == "Boats in at six")
        #expect(row.accessibilityCustomActions?.contains { $0.name == "Join" } != true)
    }

    @Test func aHistoryRowGrowsForItsCard() throws {
        let plain = PostHistoryRowCell(frame: CGRect(x: 0, y: 0, width: 360, height: 72))
        plain.configure(with: post(), viewedAt: nil, imagePipeline: nil, showsEmbed: false)
        let showcase = PostHistoryRowCell(frame: CGRect(x: 0, y: 0, width: 360, height: 72))
        showcase.configure(with: post(), viewedAt: nil, imagePipeline: nil, showsEmbed: true)
        let target = CGSize(width: 360, height: UIView.layoutFittingCompressedSize.height)
        let plainHeight = plain.systemLayoutSizeFitting(
            target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        let showcaseHeight = showcase.systemLayoutSizeFitting(
            target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        #expect(showcaseHeight > plainHeight, "the card was squeezed into the row's two lines")
    }

    // MARK: - The share

    @Test func theShareSaysTheChannelWithAndWithoutWords() {
        let embed = PostEmbed.channel(Self.channel)
        #expect(PostEmbeds.shareText(caption: "", embed: embed, drawn: true) == "📣 Harbour notes")
        #expect(PostEmbeds.shareText(caption: " Boats in at six ", embed: embed, drawn: true)
            == "📣 Harbour notes · Boats in at six")
        let long = String(repeating: "a", count: 100)
        #expect(PostEmbeds.shareText(caption: long, embed: embed, drawn: true)
            == "📣 Harbour notes · " + String(repeating: "a", count: PostEmbeds.shareCaptionLimit) + "…")
        #expect(PostEmbeds.shareText(caption: "Boats", embed: nil, drawn: true) == nil)
        #expect(PostEmbeds.shareText(caption: "Boats", embed: embed, drawn: false) == nil, "the switch off spoke")
    }
}

/// State follows (#2216, part 2): a tap on one card changes every card on
/// screen showing the same channel — in `PostEmbedViewTests`' suite, which
/// is serialized, since both set the registered actions.
extension PostEmbedViewTests {
    @Test func aJoinOnOneCardShowsOnTheSameChannelsOtherCards() async {
        let spy = SpyActions()
        spy.answer = .subscriber
        let previous = PostEmbedView.channelActions
        PostEmbedView.channelActions = spy
        ChannelEmbedLocalState.reset()
        defer {
            PostEmbedView.channelActions = previous
            ChannelEmbedLocalState.reset()
        }
        let id = ConversationID("ch-follow-\(UUID().uuidString)")
        let channel = ChannelEmbed(conversationID: id, name: "Harbour notes", subscriberCount: 3,
                                   visibility: .public, viewerState: .none)
        let tapped = PostEmbedView()
        tapped.show(.channel(channel), size: .full, pipeline: nil)
        let elsewhere = PostEmbedView()
        elsewhere.show(.channel(channel), size: .compact, pipeline: nil)
        let other = PostEmbedView()
        other.show(.channel(ChannelEmbed(conversationID: ConversationID("ch-other"), name: "Other")), size: .full, pipeline: nil)
        var told: PostEmbed?
        elsewhere.onEmbedChange = { told = $0 }

        tapped.debugTapAction()
        await tapped.debugSettle()

        #expect(tapped.debugActionTitle == "Open")
        #expect(elsewhere.debugActionTitle == "Open", "the same channel's other card kept Join")
        #expect(told?.channel?.viewerState == .subscriber, "the other card's host wasn't told")
        #expect(other.debugActionTitle == "Join", "another channel's card followed")
        // And a card drawn later, from a read made before the tap.
        let later = PostEmbedView()
        later.show(.channel(channel), size: .full, pipeline: nil)
        #expect(later.debugActionTitle == "Open")
    }
}
