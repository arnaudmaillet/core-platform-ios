import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// A channel's showcase on For You's surfaces and its share (#2216, part
/// 2): the shelf's card compact, the lift's card full under the author's
/// words, the share's text — and the plain text post with the switch off.
@MainActor
struct ShowcaseSurfacesTests {
    private let embed = PostEmbed.channel(ChannelEmbed(
        conversationID: ConversationID("ch-film"), name: "Film stock club", description: "What came back from the lab.",
        subscriberCount: 3_200, visibility: .onRequest, viewerState: .none
    ))

    private func post(caption: String, carries: Bool = true) -> GalleryPost {
        var post = GalleryPost(
            id: PostID("p-showcase"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: caption, publishedAtMS: 1_800_000_000_000,
            authorID: ProfileID("a1"), authorName: "Ava Moreau", authorHandle: "ava", reactionCount: 3
        )
        post.embed = carries ? embed : nil
        return post
    }

    @Test func aShelfsTextCardIsCompact() {
        #expect(PostGridListRowCell.embedSize(
            for: post(caption: ""), captionLines: PostShelfRows.textLines, showsEmbed: true
        ) == .compact)
        #expect(PostGridListRowCell.embedSize(for: post(caption: ""), captionLines: nil, showsEmbed: true) == .full,
                "the place page's and For You's list card is full")
    }

    // MARK: - The lift

    @Test func theLiftsCardDrawsTheCardFullUnderItsWords() throws {
        let card = TextCardPreview(
            post: post(caption: "Rolls from Sunday"), comments: [], width: 340,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), showsEmbed: true
        )
        let host = UIView(frame: CGRect(origin: .zero, size: card.size))
        card.install(in: host)
        #expect(card.embed.superview === host)
        #expect(card.embed.size == .full)
        #expect(card.embed.debugActionTitle == "Request to Join")
        #expect(!card.embed.isUserInteractionEnabled, "a lift takes no touch")
        #expect(card.caption.text == "Rolls from Sunday")
        #expect(card.embed.frame.minY >= card.caption.frame.maxY, "the card isn't under the words")
        #expect(card.size.height >= card.embed.frame.maxY, "the lift cut its card")
    }

    @Test func theLiftWithTheSwitchOffIsTodays() {
        let card = TextCardPreview(
            post: post(caption: "Rolls from Sunday"), comments: [], width: 340,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), showsEmbed: false
        )
        let host = UIView(frame: CGRect(origin: .zero, size: card.size))
        card.install(in: host)
        #expect(card.embed.superview == nil && card.embed.isHidden)
        #expect(TextCardPreview.embedSize(for: post(caption: "x"), showsEmbed: true) == .full)
        #expect(TextCardPreview.embedSize(for: post(caption: "x", carries: false), showsEmbed: true) == nil)
        #expect(TextCardPreview.embedSize(for: post(caption: "x"), showsEmbed: false) == nil)
    }

    // MARK: - The share

    @Test func theShareSaysTheChannel() {
        #expect(PostEmbeds.shareText(caption: "Rolls from Sunday", embed: embed, drawn: true)
            == "📣 Film stock club · Rolls from Sunday")
        #expect(PostEmbeds.shareText(caption: nil, embed: embed, drawn: true) == "📣 Film stock club")
        #expect(PostEmbeds.shareText(caption: "Rolls", embed: embed, drawn: false) == nil, "the switch off spoke")
    }
}
