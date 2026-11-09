import CoreModels
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
import VoiceKitUI
@testable import PostGrid

/// A voice post on the grid's surfaces (#2208): each keeps its text face and
/// draws the caption as the voice, at its room's size — full on a list card
/// and a history row, compact on a shelf's fixed card, the mark on a tile —
/// and none of it with the switch off.
@MainActor
struct VoicePostSurfaceTests {
    private let voice = PostVoice(assetID: "voice-post-hike", url: URL(fileURLWithPath: "/tmp/hike.m4a"),
                                  duration: 12.6, waveform: Array(repeating: 14, count: 100))
    private let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    private func post(caption: String = "From the ridge", speaks: Bool = true, kind: GalleryPost.Kind = .text) -> GalleryPost {
        var post = GalleryPost(
            id: PostID("p-voice"), kind: kind, isRepost: false, thumbnailURL: nil,
            caption: caption, publishedAtMS: 1_800_000_000_000,
            authorID: ProfileID("a1"), authorName: "Ava Moreau", authorHandle: "ava", reactionCount: 12
        )
        post.voice = speaks ? voice : nil
        return post
    }

    private func listCard(_ post: GalleryPost, captionLines: Int? = nil, showsVoice: Bool = true) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        cell.debugVoicePart.hub = VoicePlaybackHub.silentForTests()
        cell.configure(with: post, imagePipeline: pipeline, captionLines: captionLines, showsVoice: showsVoice)
        cell.layoutIfNeeded()
        return cell
    }

    // MARK: - Sizes

    @Test func eachSurfacePicksItsSize() {
        let speaking = post()
        #expect(PostGridListRowCell.voiceSize(for: speaking, captionLines: nil, showsVoice: true) == .full)
        #expect(PostGridListRowCell.voiceSize(for: speaking, captionLines: 2, showsVoice: true) == .compact,
                "a shelf's fixed card is compact: a drag is the shelf's")
        #expect(PostGridTileCell.voiceSize(for: speaking, showsVoice: true) == .mark)
        #expect(PostHistoryRowCell.voiceSize(for: speaking, showsVoice: true) == .full)
    }

    @Test func noSurfaceDrawsAVoiceWithTheSwitchOffOrWithoutOne() {
        for candidate in [post(speaks: false), post(kind: .photo)] {
            #expect(PostGridListRowCell.voiceSize(for: candidate, captionLines: nil, showsVoice: true) == nil)
            #expect(PostGridTileCell.voiceSize(for: candidate, showsVoice: true) == nil)
            #expect(PostHistoryRowCell.voiceSize(for: candidate, showsVoice: true) == nil)
        }
        #expect(PostGridListRowCell.voiceSize(for: post(), captionLines: nil, showsVoice: false) == nil)
        #expect(PostGridTileCell.voiceSize(for: post(), showsVoice: false) == nil)
        #expect(PostHistoryRowCell.voiceSize(for: post(), showsVoice: false) == nil)
    }

    // MARK: - The list's card

    @Test func aListCardDrawsTheVoiceFullAndTheWordsUnderIt() throws {
        let cell = listCard(post())
        let caption = try #require(cell.debugVoiceCaption)
        #expect(caption.size == .full)
        #expect(caption.voiceView?.size == .full)
        #expect(caption.voiceView?.debugTimerText == "0:12")
        #expect(cell.debugCaptionText == "From the ridge", "the words under a full voice went")
        let voiceFrame = caption.convert(caption.bounds, to: cell)
        #expect(cell.debugCaptionFrame.minY >= voiceFrame.maxY, "the words aren't under the voice")
    }

    @Test func aShelfCardDrawsTheVoiceCompactAndAlone() throws {
        let cell = listCard(post(), captionLines: 2)
        let caption = try #require(cell.debugVoiceCaption)
        #expect(caption.voiceView?.size == .compact)
        #expect(cell.debugCaptionText?.isEmpty ?? true, "a compact voice keeps no words")
    }

    @Test func theSwitchOffShowsTodaysCard() {
        let cell = listCard(post(), showsVoice: false)
        #expect(cell.debugVoiceCaption == nil)
        #expect(cell.debugCaptionText == "From the ridge")
    }

    @Test func aCardsTapOutsideTheVoiceStaysTheCards() throws {
        let cell = listCard(post())
        let player = try #require(cell.debugVoiceCaption?.voiceView)
        let button = player.debugPlayButton
        let onButton = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: player)
        #expect(player.keepsPress(at: onButton), "the play button gave its tap to the card")
        // The card's caption, well below the voice: the voice keeps nothing there.
        let below = cell.convert(CGPoint(x: cell.debugCaptionFrame.midX, y: cell.debugCaptionFrame.midY), to: player)
        #expect(!player.keepsPress(at: below), "the voice took the card's tap")
    }

    @Test func aReusedCardStopsItsVoice() throws {
        let cell = listCard(post())
        let caption = try #require(cell.debugVoiceCaption)
        let hub = caption.hub
        let id = VoicePlaybackHub.postID("p-voice")
        caption.voiceView?.onPlayTap?()
        #expect(hub.isPlaying(id))
        cell.prepareForReuse()
        #expect(!hub.isPlaying(id), "a reused card kept playing")
        #expect(cell.debugVoiceCaption == nil)
    }

    @Test func aCardScrolledOffStopsItsVoice() throws {
        let cell = listCard(post())
        let caption = try #require(cell.debugVoiceCaption)
        caption.voiceView?.onPlayTap?()
        cell.voiceDidEndDisplaying()
        #expect(!caption.hub.isPlaying(VoicePlaybackHub.postID("p-voice")))
    }

    // MARK: - The tile

    @Test func aTileWearsTheMarkAndATapStaysTheTiles() throws {
        let tile = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 160))
        tile.configure(with: post(), imagePipeline: pipeline, showsVoice: true)
        let mark = try #require(tile.debugVoiceMark)
        #expect(mark.size == .mark)
        #expect(mark.markView?.debugDurationText == "0:12")
        #expect(!mark.isUserInteractionEnabled, "the mark takes the tile's tap")
        #expect(tile.accessibilityLabel == "Voice post by Ava Moreau, 13 seconds")

        let plain = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 160))
        plain.configure(with: post(), imagePipeline: pipeline, showsVoice: false)
        #expect(plain.debugVoiceMark == nil, "the switch off drew a mark")

        tile.prepareForReuse()
        tile.configure(with: post(speaks: false), imagePipeline: pipeline, showsVoice: true)
        #expect(tile.debugVoiceMark == nil, "a reused tile kept the last post's mark")
        #expect(tile.accessibilityLabel == nil)
    }

    // MARK: - The history row

    @Test func aHistoryRowSpeaksInItsTitlesPlace() throws {
        let row = PostHistoryRowCell(frame: CGRect(x: 0, y: 0, width: 360, height: 72))
        row.debugVoicePart.hub = VoicePlaybackHub.silentForTests()
        row.configure(with: post(), viewedAt: nil, imagePipeline: nil, showsVoice: true)
        let caption = try #require(row.debugVoiceCaption)
        #expect(caption.voiceView?.size == .full)
        #expect(!row.debugShowsTitle)
        #expect(row.accessibilityLabel?.hasPrefix("Voice post, 13 seconds, From the ridge") == true)
        #expect(row.accessibilityCustomActions?.contains { $0.name == "Play or pause the voice" } == true)

        let id = VoicePlaybackHub.postID("p-voice")
        caption.voiceView?.onPlayTap?()
        #expect(caption.hub.isPlaying(id))
        row.prepareForReuse()
        #expect(!caption.hub.isPlaying(id), "a reused row kept playing")

        row.configure(with: post(), viewedAt: nil, imagePipeline: nil, showsVoice: false)
        #expect(row.debugVoiceCaption == nil)
        #expect(row.debugShowsTitle && row.debugTitle == "From the ridge")
    }

    @Test func aSpeakingRowsSquareHoldsTheVoicesLine() {
        let title = PostHistoryRowCell.titleFont()
        let detail = PostHistoryRowCell.detailFont()
        let plain = PostHistoryRowCell.squareSide(titleFont: title, detailFont: detail, wraps: false)
        let speaking = PostHistoryRowCell.squareSide(titleFont: title, detailFont: detail, wraps: false, speaks: true)
        #expect(speaking >= plain)
        #expect(speaking >= VoiceView.buttonSide + 2 * PostHistoryRowCell.verticalPadding)
    }
}
