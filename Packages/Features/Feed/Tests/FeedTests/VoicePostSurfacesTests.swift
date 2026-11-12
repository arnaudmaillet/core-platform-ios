import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
import VoiceKitUI
@testable import Feed
@testable import ThreadKit

/// A voice post on For You's surfaces and its share (#2208): the shelf's
/// card compact, the lift's card full with its words under the voice, the
/// share's text, and one playback id for the card and the page.
@MainActor
struct VoicePostSurfacesTests {
    private let voice = PostVoice(assetID: "voice-post-hike", url: URL(fileURLWithPath: "/tmp/hike.m4a"),
                                  duration: 32.4, waveform: Array(repeating: 14, count: 100))

    private func post(caption: String, speaks: Bool = true) -> GalleryPost {
        var post = GalleryPost(
            id: PostID("p-voice"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: caption, publishedAtMS: 1_800_000_000_000,
            authorID: ProfileID("a1"), authorName: "Ava Moreau", authorHandle: "ava", reactionCount: 3
        )
        post.voice = speaks ? voice : nil
        return post
    }

    @Test func theCardAndThePagePlayUnderOneID() {
        #expect(VoicePosts.playbackID(PostID("p-voice")) == VoicePlaybackHub.postID("p-voice"))
    }

    @Test func aShelfsTextCardIsCompact() {
        #expect(PostGridListRowCell.voiceSize(
            for: post(caption: ""), captionLines: PostShelfRows.textLines, showsVoice: true
        ) == .compact)
    }

    // MARK: - The lift

    @Test func theLiftsCardDrawsTheVoiceFullAndItsWordsUnderIt() throws {
        let card = TextCardPreview(
            post: post(caption: "From the ridge"), comments: [], width: 340,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            showsVoice: true, voiceHub: VoicePlaybackHub.silentForTests()
        )
        let host = UIView(frame: CGRect(origin: .zero, size: card.size))
        card.install(in: host)
        #expect(card.voice.superview === host)
        #expect(card.voice.size == .full)
        #expect(card.voice.voiceView?.debugTimerText == "32\u{2033}")
        #expect(card.caption.frame.minY >= card.voice.frame.maxY, "the words aren't under the voice")
        #expect(card.caption.text == "From the ridge")
    }

    @Test func theLiftWithTheSwitchOffIsTodays() {
        let card = TextCardPreview(
            post: post(caption: "From the ridge"), comments: [], width: 340,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), showsVoice: false
        )
        let host = UIView(frame: CGRect(origin: .zero, size: card.size))
        card.install(in: host)
        #expect(card.voice.superview == nil && card.voice.isHidden)
        #expect(TextCardPreview.voiceSize(for: post(caption: "x"), showsVoice: true) == .full)
        #expect(TextCardPreview.voiceSize(for: post(caption: "x", speaks: false), showsVoice: true) == nil)
    }

    // MARK: - The share

    @Test func theShareSaysTheVoiceWithAndWithoutWords() {
        #expect(VoicePosts.shareText(caption: "", voice: voice, showsVoice: true) == "🎙 Voice post · 32\u{2033}")
        #expect(VoicePosts.shareText(caption: " From the ridge ", voice: voice, showsVoice: true) == "🎙 From the ridge")
        let long = String(repeating: "a", count: 100)
        #expect(VoicePosts.shareText(caption: long, voice: voice, showsVoice: true)
            == "🎙 " + String(repeating: "a", count: VoicePosts.shareCaptionLimit) + "…")
        #expect(VoicePosts.shareText(caption: "From the ridge", voice: nil, showsVoice: true) == nil)
        #expect(VoicePosts.shareText(caption: "", voice: voice, showsVoice: false) == nil, "the switch off spoke")
    }
}
