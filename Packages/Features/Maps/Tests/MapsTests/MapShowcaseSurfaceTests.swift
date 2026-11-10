import CoreModels
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Maps

/// A channel's showcase on the map (#2216, part 2): its pin is a text pin
/// with the channel's megaphone (the mark, on a 44 pt disc); the text bubble
/// draws the full card under the author's words, its button's touch its
/// own, the rest of the bubble its marker's; and none of it with the switch
/// off.
@MainActor
struct MapShowcaseSurfaceTests {
    private static let channel = ChannelEmbed(
        conversationID: ConversationID("ch-printroom"), name: "Print room", description: "Darkroom hours.",
        subscriberCount: 820, visibility: .public, viewerState: .none
    )
    private let embed = PostEmbed.channel(Self.channel)

    private func pin(kind: MapPin.Kind = .text, embed: PostEmbed? = .channel(channel), voice: PostVoice? = nil) -> MapPin {
        MapPin(postID: PostID("p-showcase"), latitude: 48.85, longitude: 2.35, thumbnailURL: nil, kind: kind,
               voice: voice, embed: embed)
    }

    private func post(caption: String, embed: PostEmbed? = .channel(channel)) -> GalleryPost {
        var post = GalleryPost(
            id: PostID("p-showcase"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: caption, publishedAtMS: 1_800_000_000_000,
            authorID: ProfileID("ava"), authorName: "Ava Moreau", authorHandle: "ava"
        )
        post.embed = embed
        return post
    }

    // MARK: - The pin

    @Test func aShowcasePinIsATextPinWithTheMegaphone() {
        #expect(pin().wearsChannelMark(showsEmbed: true))
        #expect(!pin().wearsChannelMark(showsEmbed: false), "the switch off drew a mark")
        #expect(!pin(embed: nil).wearsChannelMark(showsEmbed: true))
        #expect(!pin(kind: .photo).wearsChannelMark(showsEmbed: true))
    }

    @Test func theMarkerWearsTheMarkAndSaysSo() {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let view = MapAnnotationView(annotation: nil, reuseIdentifier: MapAnnotationView.reuseIdentifier)
        view.configure(with: pin(), imagePipeline: pipeline, showsEmbed: true)
        #expect(view.debugWearsChannelMark)
        #expect(!view.debugWearsVoiceMark)
        #expect(view.accessibilityValue == "Channel Print room, 820 subscribers")
        view.prepareForReuse()
        #expect(!view.debugWearsChannelMark, "a recycled marker kept the mark")
        view.configure(with: pin(), imagePipeline: pipeline, showsEmbed: false)
        #expect(!view.debugWearsChannelMark, "the switch off drew a mark")
        #expect(view.accessibilityValue == nil)
    }

    @Test func theChannelsMarkOutranksTheVoices() {
        let voice = PostVoice(assetID: "v", url: URL(fileURLWithPath: "/tmp/v.m4a"), duration: 12,
                              waveform: Array(repeating: 10, count: 100))
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let view = MapAnnotationView(annotation: nil, reuseIdentifier: MapAnnotationView.reuseIdentifier)
        view.configure(with: pin(voice: voice), imagePipeline: pipeline, showsVoice: true, showsEmbed: true)
        #expect(view.debugWearsChannelMark)
        #expect(!view.debugWearsVoiceMark, "one plate, two glyphs")
    }

    // MARK: - The bubble

    private func bubble(caption: String, showsEmbed: Bool = true) -> MapTextBubbleView {
        let bubble = MapTextBubbleView()
        bubble.markerSide = 44 * MapFeaturedHalo.scale
        bubble.setContent(.of(post(caption: caption), showsVoice: false, showsEmbed: showsEmbed))
        bubble.frame.size = bubble.sizeThatFits(.zero)
        bubble.layoutIfNeeded()
        return bubble
    }

    @Test func theBubbleDrawsTheCardFullUnderTheWords() throws {
        let worded = bubble(caption: "Prints from Sunday")
        let card = try #require(worded.debugEmbed)
        #expect(card.size == .full)
        #expect(card.debugActionTitle == "Join")
        #expect(!worded.label.isHidden && worded.label.text == "Prints from Sunday")
        let cardFrame = card.convert(card.bounds, to: worded)
        let wordsFrame = worded.label.convert(worded.label.bounds, to: worded)
        #expect(cardFrame.minY >= wordsFrame.maxY, "the card isn't under the words")
        #expect(worded.bounds.contains(cardFrame), "the bubble doesn't hold its card")

        let alone = bubble(caption: "")
        #expect(alone.debugEmbed != nil)
        #expect(alone.label.isHidden, "an empty line above a card alone")
    }

    @Test func theSwitchOffShowsTodaysBubble() {
        #expect(MapTextBubbleView.Content.of(post(caption: "x"), showsEmbed: false).embed == nil)
        let plain = bubble(caption: "Prints from Sunday", showsEmbed: false)
        #expect(plain.debugEmbed == nil)
        #expect(plain.label.text == "Prints from Sunday")
    }

    @Test func thePinsCardStandsInForAPostReadWithoutOne() {
        let content = MapTextBubbleView.Content.of(post(caption: "x", embed: nil), pinEmbed: embed, showsEmbed: true)
        #expect(content.embed == embed)
    }

    @Test func onlyTheCardsButtonTakesATouch() throws {
        let worded = bubble(caption: "Prints from Sunday")
        let card = try #require(worded.debugEmbed)
        let button = card.debugActionButton
        let onButton = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: worded)
        let hit = worded.hitTest(onButton, with: nil)
        #expect(hit != nil && PostEmbedView.keepsTouch(on: hit), "the button gave its tap to the marker")
        // The card's photo and name, and the words: the marker's, which opens the post.
        let onCard = card.convert(CGPoint(x: 4, y: 4), to: worded)
        #expect(worded.hitTest(onCard, with: nil) == nil, "the card took the marker's tap")
        let onWords = worded.label.convert(CGPoint(x: worded.label.bounds.midX, y: worded.label.bounds.midY), to: worded)
        #expect(worded.hitTest(onWords, with: nil) == nil, "the words took the marker's tap")
        // Folded: nothing takes a touch.
        worded.setWordsShown(false)
        #expect(worded.hitTest(onButton, with: nil) == nil)
    }
}
