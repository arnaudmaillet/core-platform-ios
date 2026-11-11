import CoreModels
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
import VoiceKitUI
@testable import PostGrid

/// A voice post on the grid's surfaces (#2208): each keeps its text face and
/// draws the caption as the voice, at its room's size — full on a list card,
/// compact on a shelf's fixed card and a history row (#2241), the mark on a
/// tile — and none of it with the switch off. The voice is the neutral panel
/// (#2241), across the width its surface gives.
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
                "a shelf's fixed card is compact")
        #expect(PostGridTileCell.voiceSize(for: speaking, showsVoice: true) == .mark)
        #expect(PostHistoryRowCell.voiceSize(for: speaking, showsVoice: true) == .compact,
                "a history row is compact (#2241): a shorter panel")
    }

    /// The drags are the panel's (#2275) on every surface but a shelf's
    /// fixed card, whose scroll takes them.
    @Test func onlyAShelfsCardGivesItsDragsAway() {
        #expect(PostGridListRowCell.voiceDragsAreOwn(captionLines: nil))
        #expect(!PostGridListRowCell.voiceDragsAreOwn(captionLines: 2), "a drag on a shelf card's panel is the shelf's")
        #expect(PostHistoryRowCell.voiceDragsAreOwn, "a history row's panel gave its drags away")
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
        #expect(caption.voiceView?.debugTimerText == "12\u{2033}")
        #expect(cell.debugCaptionText == "From the ridge", "the words under a full voice went")
        let voiceFrame = caption.convert(caption.bounds, to: cell)
        #expect(cell.debugCaptionFrame.minY >= voiceFrame.maxY, "the words aren't under the voice")
    }

    /// The panel takes the caption's whole width on a list card and a
    /// shelf's card (#2241), whatever the voice's length.
    @Test(arguments: [nil, 2] as [Int?])
    func aCardsPanelFillsTheCaptionsWidth(_ captionLines: Int?) throws {
        var short = post()
        short.voice = PostVoice(assetID: "short", url: voice.url, duration: 2, waveform: voice.waveform)
        var long = post()
        long.voice = PostVoice(assetID: "long", url: voice.url, duration: 50, waveform: voice.waveform)
        let widths = try [short, long].map { candidate -> CGFloat in
            let cell = listCard(candidate, captionLines: captionLines)
            let caption = try #require(cell.debugVoiceCaption)
            let player = try #require(caption.voiceView)
            player.layoutIfNeeded()
            #expect(abs(player.debugPanelFrame.width - caption.bounds.width) < 0.5,
                    "\(player.debugPanelFrame) in \(caption.bounds)")
            #expect(caption.bounds.width > 250, "the voice didn't take the card's width")
            return player.debugPanelFrame.width
        }
        #expect(widths[0] == widths[1], "a 2 s and a 50 s voice drew different panels")
    }

    /// A list card's panel claims its drags; a shelf's card gives them to
    /// the shelf — a tap still seeks — and the same cell reused on a list
    /// claims them again (#2275).
    @Test func aShelfCardsDragsAreTheShelfs() throws {
        let list = listCard(post())
        let listPlayer = try #require(list.debugVoiceCaption?.voiceView)
        #expect(listPlayer.dragsAreOwn && listPlayer.debugSideHoldEnabled && listPlayer.waveform.scrubs)

        let cell = listCard(post(), captionLines: 2)
        let player = try #require(cell.debugVoiceCaption?.voiceView)
        #expect(!player.dragsAreOwn && !player.debugSideHoldEnabled && !player.debugPlayHoldEnabled)
        #expect(!player.waveform.scrubs, "a drag on a shelf card's waveform would fight the shelf's scroll")
        let taps = player.waveform.gestureRecognizers?.filter { $0 is UITapGestureRecognizer && $0.isEnabled } ?? []
        #expect(!taps.isEmpty, "a shelf card's waveform no longer seeks on a tap")

        cell.prepareForReuse()
        cell.configure(with: post(), imagePipeline: pipeline, captionLines: nil, showsVoice: true)
        let reused = try #require(cell.debugVoiceCaption?.voiceView)
        #expect(reused.dragsAreOwn && reused.debugSideHoldEnabled, "a reused card kept the shelf's rule")
    }

    @Test func aShelfCardDrawsTheVoiceCompactAndAlone() throws {
        let cell = listCard(post(), captionLines: 2)
        let caption = try #require(cell.debugVoiceCaption)
        #expect(caption.voiceView?.size == .compact)
        #expect(cell.debugCaptionText?.isEmpty ?? true, "a compact voice keeps no words")
    }

    /// A shelf's lane is tall enough for a voice post (#2274): its fixed
    /// card holds the compact panel at its full 44 pt, the line centred in
    /// it, above the closing line — the panel is never squeezed.
    @Test func aShelfsFixedCardHoldsTheCompactPanelWhole() throws {
        let width: CGFloat = 322
        let textOnly = PostGridListRowCell.fixedTextCardHeight(width: width, captionLines: 2, showsVoice: false)
        let height = PostGridListRowCell.fixedTextCardHeight(width: width, captionLines: 2, showsVoice: true)
        #expect(height >= textOnly)
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: height))
        cell.debugVoicePart.hub = VoicePlaybackHub.silentForTests()
        let words = String(repeating: "A long post that goes on and on about nothing much. ", count: 10)
        cell.configure(with: post(caption: words), imagePipeline: pipeline, captionLines: 2, showsVoice: true)
        cell.onRepostTapped = {}
        cell.onBookmarkTapped = {}
        cell.onStake = { _ in }
        cell.layoutIfNeeded()
        let player = try #require(cell.debugVoiceCaption?.voiceView)
        player.layoutIfNeeded()
        let panel = player.debugPanelFrame
        #expect(panel.height == VoiceView.panelHeight(for: .compact), "the shelf squeezed the panel: \(panel)")
        let line = player.debugLineFrame
        #expect(abs((line.minY - panel.minY) - (panel.maxY - line.maxY)) < 0.5, "\(line) off centre in \(panel)")
        let drawn = player.convert(panel, to: cell)
        let closing = cell.debugClosingLineFrame
        #expect(!closing.isNull)
        #expect(drawn.maxY <= closing.minY + 0.5, "\(drawn) runs into the closing line \(closing)")
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
        #expect(mark.markView?.debugDurationText == "12\u{2033}")
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
        #expect(caption.voiceView?.size == .compact)
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

    /// ⚠️ THE OWNER'S RECORDING (#2275): a sideways drag on a history row's
    /// voice moved the profile's pages. Compact as it is, its drags are its
    /// own: the pager around the list (a paging scroll view, as the
    /// profile's) and the list's own scroll wait for the panel's sideways
    /// hold and its scrub; a vertical drag still scrolls the list (the hold
    /// takes only a sideways one).
    @Test func aHistoryRowsPanelHoldsThePagerBack() throws {
        let pager = HorizontalPagerScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 640))
        pager.isPagingEnabled = true
        pager.contentSize = CGSize(width: 360 * 3, height: 640)
        let list = UIScrollView(frame: CGRect(x: 720, y: 0, width: 360, height: 640))
        pager.addSubview(list)
        let row = PostHistoryRowCell(frame: CGRect(x: 0, y: 0, width: 360, height: 72))
        row.debugVoicePart.hub = VoicePlaybackHub.silentForTests()
        row.configure(with: post(), viewedAt: nil, imagePipeline: nil, showsVoice: true)
        list.addSubview(row)
        row.layoutIfNeeded()
        let player = try #require(row.debugVoiceCaption?.voiceView)
        #expect(player.size == .compact)
        #expect(player.dragsAreOwn && player.debugSideHoldEnabled && player.debugPlayHoldEnabled)
        #expect(player.waveform.scrubs, "a sideways drag on a history row's waveform doesn't scrub")
        let scrub = try #require(player.debugScrub)
        for other in [pager.panGestureRecognizer, list.panGestureRecognizer] {
            #expect(player.gestureRecognizer(player.debugSideHold, shouldBeRequiredToFailBy: other),
                    "the pager's pan didn't wait for the panel's sideways drag")
            #expect(player.waveform.gestureRecognizer(scrub, shouldBeRequiredToFailBy: other))
        }
    }

    @Test func aSpeakingRowsSquareHoldsTheVoicesLine() {
        let title = PostHistoryRowCell.titleFont()
        let detail = PostHistoryRowCell.detailFont()
        let plain = PostHistoryRowCell.squareSide(titleFont: title, detailFont: detail, wraps: false)
        let speaking = PostHistoryRowCell.squareSide(titleFont: title, detailFont: detail, wraps: false, speaks: true)
        #expect(speaking >= plain)
        #expect(speaking >= VoiceView.panelHeight(for: .compact) + 2 * PostHistoryRowCell.verticalPadding)
    }
}
