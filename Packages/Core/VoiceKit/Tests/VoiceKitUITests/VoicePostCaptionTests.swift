import Testing
import UIKit
@testable import VoiceKitUI

/// A voice post's caption on a card, a tile or a bubble (#2208): the size
/// asked for, one id per post, and a voice that stops when its card leaves
/// the screen — unless the post's page shows it.
@MainActor
struct VoicePostCaptionTests {
    private let url = URL(fileURLWithPath: "/tmp/voice.m4a")

    private func caption(_ size: VoicePostDisplay.Size, hub: VoicePlaybackHub, postID: String = "p1") -> VoicePostCaptionView {
        let view = VoicePostCaptionView()
        view.hub = hub
        view.show(postID: postID, url: url, duration: 32, levels: [], author: "Ava", size: size)
        return view
    }

    @Test func thePostsIDIsTheSameEverywhere() {
        #expect(VoicePlaybackHub.postID("p1") == "post-p1")
    }

    @Test func eachSizeDrawsItsPart() {
        let hub = VoicePlaybackHub.silentForTests()
        let full = caption(.full, hub: hub)
        #expect(full.voiceView?.size == .full && full.markView == nil)
        #expect(full.playbackID == "post-p1")
        let compact = caption(.compact, hub: hub)
        #expect(compact.voiceView?.size == .compact)
        let mark = caption(.mark, hub: hub)
        #expect(mark.voiceView == nil && mark.markView != nil && mark.playbackID == nil, "a mark plays")
        #expect(mark.accessibilityDescription == "Voice post by Ava, 32 seconds")

        // Shown again at another size, it swaps its part.
        full.show(postID: "p1", url: url, duration: 32, levels: [], author: nil, size: .mark)
        #expect(full.voiceView == nil && full.markView != nil)
        full.clear()
        #expect(full.isHidden && full.size == nil)
    }

    /// A caption's drags are its own by default, at both sizes (#2275); a
    /// host turns them off (a shelf's card), and the next show says it again
    /// — a reused cell never keeps the last host's rule.
    @Test func theDragsAreThePanelsUnlessTheHostSaysOtherwise() throws {
        let hub = VoicePlaybackHub.silentForTests()
        for size in [VoicePostDisplay.Size.full, .compact] {
            let shown = caption(size, hub: hub)
            let player = try #require(shown.voiceView)
            #expect(shown.dragsAreOwn && player.dragsAreOwn, "\(size): the default gave the drags away")
            #expect(player.debugSideHoldEnabled && player.waveform.scrubs)
        }
        let card = VoicePostCaptionView()
        card.hub = hub
        card.show(postID: "p1", url: url, duration: 32, levels: [], author: nil, size: .compact, dragsAreOwn: false)
        let player = try #require(card.voiceView)
        #expect(!card.dragsAreOwn && !player.dragsAreOwn)
        #expect(!player.debugSideHoldEnabled && !player.waveform.scrubs)
        card.show(postID: "p2", url: url, duration: 10, levels: [], author: nil, size: .compact)
        #expect(card.voiceView === player, "the same size kept its player")
        #expect(player.dragsAreOwn && player.debugSideHoldEnabled && player.waveform.scrubs,
                "a reused card kept the shelf's rule")
    }

    @Test func theInkIsTheGrounds() {
        let hub = VoicePlaybackHub.silentForTests()
        let inks = VoiceView.Inks(played: .white, unplayed: .gray, timer: .lightGray)
        let full = caption(.full, hub: hub)
        full.inks = inks
        #expect(full.voiceView?.inks == inks)
        let mark = caption(.mark, hub: hub)
        mark.inks = inks
        #expect(mark.markView?.ink == .white)
    }

    @Test func aCardLeavingTheScreenStopsItsVoice() {
        let hub = VoicePlaybackHub.silentForTests()
        let card = caption(.compact, hub: hub)
        card.voiceView?.onPlayTap?()
        #expect(hub.isPlaying("post-p1"))
        card.leftScreen()
        #expect(!hub.isPlaying("post-p1"))
    }

    @Test func theVoiceGoesOnWhenThePageShowsIt() {
        let hub = VoicePlaybackHub.silentForTests()
        let card = caption(.compact, hub: hub)
        card.voiceView?.onPlayTap?()
        // The post's page, on screen, binds the same voice.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.isHidden = false
        let page = VoiceView(size: .full)
        window.addSubview(page)
        hub.bind(page, id: "post-p1", url: url, duration: 32, levels: nil)
        card.leftScreen()
        #expect(hub.isPlaying("post-p1"), "the card stopped the voice its page plays")
        page.removeFromSuperview()
        window.isHidden = true
    }

    @Test func aReusedCardLetsItsVoiceGo() {
        let hub = VoicePlaybackHub.silentForTests()
        let card = caption(.full, hub: hub)
        card.voiceView?.onPlayTap?()
        card.show(postID: "p2", url: url, duration: 10, levels: [], author: nil, size: .full)
        #expect(!hub.isPlaying("post-p1"), "a card shown for another post kept playing the last one")
        #expect(card.playbackID == "post-p2")
    }
}
