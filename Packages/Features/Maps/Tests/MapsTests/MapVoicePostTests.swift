import CoreModels
import MediaCore
import PostGrid
import Testing
import UIKit
import VoiceKitUI
@testable import Maps

/// A voice post on the map (#2208): a voice pin is a text pin with the mic;
/// the text bubble draws the voice — the compact neutral panel across its
/// column (#2241) — in the words' place, its taps its own, the rest of the
/// bubble its marker's; and none of it with the switch off.
@MainActor
struct MapVoicePostTests {
    private let voice = PostVoice(assetID: "voice-post-hike", url: URL(fileURLWithPath: "/tmp/hike.m4a"),
                                  duration: 12.6, waveform: Array(repeating: 14, count: 100))

    private func pin(kind: MapPin.Kind = .text, speaks: Bool = true) -> MapPin {
        MapPin(postID: PostID("p-voice"), latitude: 48.85, longitude: 2.35, thumbnailURL: nil, kind: kind,
               voice: speaks ? voice : nil)
    }

    private func post(caption: String) -> GalleryPost {
        var post = GalleryPost(
            id: PostID("p-voice"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: caption, publishedAtMS: 1_800_000_000_000,
            authorID: ProfileID("ava"), authorName: "Ava Moreau", authorHandle: "ava"
        )
        post.voice = voice
        return post
    }

    // MARK: - The pin

    @Test func aVoicePinIsATextPinWithTheMic() {
        #expect(pin().wearsVoiceMark(showsVoice: true))
        #expect(!pin().wearsVoiceMark(showsVoice: false), "the switch off drew a mic")
        #expect(!pin(speaks: false).wearsVoiceMark(showsVoice: true))
        #expect(!pin(kind: .photo).wearsVoiceMark(showsVoice: true))
    }

    @Test func theMarkerWearsTheMicAndSaysSo() {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let view = MapAnnotationView(annotation: nil, reuseIdentifier: MapAnnotationView.reuseIdentifier)
        view.configure(with: pin(), imagePipeline: pipeline, showsVoice: true)
        #expect(view.debugWearsVoiceMark)
        #expect(view.accessibilityValue == "Voice post, 13 seconds")
        view.prepareForReuse()
        #expect(!view.debugWearsVoiceMark, "a recycled marker kept the mic")
        view.configure(with: pin(), imagePipeline: pipeline, showsVoice: false)
        #expect(!view.debugWearsVoiceMark)
        #expect(view.accessibilityValue == nil)
    }

    // MARK: - The bubble

    private func bubble(caption: String) -> MapTextBubbleView {
        let bubble = MapTextBubbleView()
        bubble.voiceCaption.hub = VoicePlaybackHub.silentForTests()
        bubble.markerSide = 44 * MapFeaturedHalo.scale
        bubble.setContent(.of(post(caption: caption), showsVoice: true))
        bubble.layoutIfNeeded()
        return bubble
    }

    @Test func theBubbleSpeaksInTheWordsPlace() throws {
        #expect(MapTextBubbleView.Content.of(post(caption: ""), showsVoice: false).voice == nil)
        let alone = bubble(caption: "")
        let shown = try #require(alone.debugVoice)
        #expect(shown.voiceView?.size == .compact, "the bubble's voice is compact (#2241's table)")
        #expect(alone.label.isHidden, "an empty line under a voice alone")
        #expect(shown.voiceView?.inks == MapTextBubbleView.voiceInks, "the voice didn't take the glass's ink")

        let worded = bubble(caption: "From the ridge")
        let voiceFrame = try #require(worded.debugVoice).frame
        #expect(!worded.label.isHidden)
        #expect(worded.label.frame.minY >= voiceFrame.maxY, "the words aren't under the voice")
    }

    /// The panel takes the bubble's whole column whatever the voice's
    /// length (#2241), its ground the glass's ink at the panel's opacity.
    @Test func thePanelTakesTheColumn() throws {
        let worded = bubble(caption: "From the ridge")
        let caption = try #require(worded.debugVoice)
        #expect(caption.frame.width == MapTextBubbleView.textWidth)
        #expect(worded.debugColumnFrame.width == MapTextBubbleView.textWidth)
        let player = try #require(caption.voiceView)
        player.layoutIfNeeded()
        #expect(abs(player.debugPanelFrame.width - MapTextBubbleView.textWidth) < 0.5, "\(player.debugPanelFrame)")
        #expect(caption.frame.height >= VoiceView.panelHeight(for: .compact))

        let light = UITraitCollection(userInterfaceStyle: .light)
        let ground = try #require(player.debugPanelFill).resolvedColor(with: light)
        let ink = UIColor.label.resolvedColor(with: light)
        var groundWhite: CGFloat = 0, groundAlpha: CGFloat = 0, inkWhite: CGFloat = 0
        ground.getWhite(&groundWhite, alpha: &groundAlpha)
        ink.getWhite(&inkWhite, alpha: nil)
        #expect(abs(groundWhite - inkWhite) < 0.01, "the panel isn't the glass's ink")
        #expect(abs(groundAlpha - VoiceView.Inks.panelOpacityLight) < 0.01)
    }

    @Test func onlyTheVoiceTakesATouch() throws {
        let worded = bubble(caption: "From the ridge")
        let player = try #require(worded.debugVoice?.voiceView)
        let button = player.debugPlayButton
        let onButton = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: worded)
        #expect(worded.hitTest(onButton, with: nil) != nil, "the play button gave its tap to the marker")
        let onWords = worded.label.convert(CGPoint(x: worded.label.bounds.midX, y: worded.label.bounds.midY), to: worded)
        #expect(worded.hitTest(onWords, with: nil) == nil, "the words took the marker's tap")
    }

    /// The bubble's voice is compact, and its drags are its own (#2275): the
    /// map's pan waits for the panel's sideways hold and its scrub, so a
    /// sideways drag on it scrubs and the map doesn't pan.
    @Test func theBubblesPanelHoldsTheMapBack() throws {
        #expect(MapTextBubbleView.voiceDragsAreOwn)
        let map = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let mapPan = UIPanGestureRecognizer()
        map.addGestureRecognizer(mapPan)
        let worded = bubble(caption: "From the ridge")
        map.addSubview(worded)
        let player = try #require(worded.debugVoice?.voiceView)
        #expect(player.size == .compact)
        #expect(player.dragsAreOwn && player.debugSideHoldEnabled && player.debugPlayHoldEnabled)
        #expect(player.waveform.scrubs, "a sideways drag on the bubble's waveform doesn't scrub")
        let scrub = try #require(player.debugScrub)
        #expect(player.gestureRecognizer(player.debugSideHold, shouldBeRequiredToFailBy: mapPan),
                "the map's pan didn't wait for the panel's sideways drag")
        #expect(player.waveform.gestureRecognizer(scrub, shouldBeRequiredToFailBy: mapPan))
    }

    /// A sideways drag anywhere on the panel is the panel's (#2275): its
    /// ground beside the waveform — the timer's place — takes the touch too.
    /// Off the panel, the marker keeps it.
    @Test func theWholePanelTakesItsDrag() throws {
        let worded = bubble(caption: "From the ridge")
        let player = try #require(worded.debugVoice?.voiceView)
        player.layoutIfNeeded()
        let timer = player.debugTimerFrame
        let onTimer = player.convert(CGPoint(x: timer.midX, y: timer.midY), to: worded)
        #expect(!player.keepsPress(at: CGPoint(x: timer.midX, y: timer.midY)), "the timer became a press of the voice's")
        #expect(worded.hitTest(onTimer, with: nil) != nil, "the panel's ground gave its drag to the map")
        let onAuthor = worded.authorLabel.convert(
            CGPoint(x: worded.authorLabel.bounds.midX, y: worded.authorLabel.bounds.midY), to: worded
        )
        #expect(worded.hitTest(onAuthor, with: nil) == nil, "the author's line took the marker's tap")
    }

    @Test func aFoldedBubbleStopsItsVoice() throws {
        let worded = bubble(caption: "")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.isHidden = false
        window.addSubview(worded)
        let caption = try #require(worded.debugVoice)
        caption.voiceView?.onPlayTap?()
        let id = VoicePlaybackHub.postID("p-voice")
        #expect(caption.hub.isPlaying(id))
        worded.removeFromSuperview()
        #expect(!caption.hub.isPlaying(id), "the voice went on with its bubble gone")
        window.isHidden = true
    }
}
