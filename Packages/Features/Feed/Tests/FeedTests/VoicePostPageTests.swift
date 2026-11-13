import AVFoundation
import CoreModels
import Testing
import UIKit
import VoiceKit
import VoiceKitUI
@testable import Feed
@testable import ThreadKit

/// A voice post's text page (#2207): the caption row is the shared voice
/// component, full size, the caption's words under it; it plays by tap,
/// keyed by the post, and stops when the row leaves.
@MainActor
struct VoicePostPageTests {
    final class Session: VoiceAudioSessionControlling {
        var isInputAvailable = true
        func setCategory(
            _ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
        ) throws {}
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
        func setAllowHapticsAndSystemSoundsDuringRecording(_ allow: Bool) throws {}
    }

    final class Engine: VoicePlaybackEngine {
        var onEnd: (() -> Void)?
        var onFailure: (() -> Void)?
        var currentTime: TimeInterval = 0
        var duration: TimeInterval? = 10
        func load(_ url: URL) {}
        func play(rate: Float) {}
        func pause() {}
        func seek(to seconds: TimeInterval) { currentTime = seconds }
    }

    private let voice = PostVoice(assetID: "voice-post-hike", url: URL(fileURLWithPath: "/tmp/hike.m4a"),
                                  duration: 12.6, waveform: Array(repeating: 14, count: 100))

    private func entry(caption: String, voice: PostVoice?) -> FeedEntry {
        FeedEntry(
            post: Post(id: PostID("p-voice"), authorID: ProfileID("prof-1"), caption: caption, attachments: [],
                       publishedAt: Date(timeIntervalSince1970: 1_800_000_000), voice: voice),
            author: AuthorSummary(id: ProfileID("prof-1"), handle: "ava", displayName: "Ava Moreau", avatarURL: nil)
        )
    }

    private func hub() -> VoicePlaybackHub {
        let name = "voice-page-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let center = NotificationCenter()
        let player = VoicePlayer(session: Session(), makeEngine: { Engine() }, defaults: defaults, notifications: center)
        return VoicePlaybackHub(player: player, notifications: center)
    }

    // MARK: - The row

    @Test func theModelCarriesTheVoiceOnlyWithTheFlag() {
        let speaking = PostDetailDisplayModel(entry: entry(caption: "", voice: voice), showsVoice: true)
        #expect(speaking.voice == voice)
        #expect(speaking.showsCaptionRow, "a voice alone has no caption row")
        #expect(!speaking.hasCaption && !speaking.hasMedia)
        let off = PostDetailDisplayModel(entry: entry(caption: "", voice: voice), showsVoice: false)
        #expect(off.voice == nil && !off.showsCaptionRow, "the flag off drew a voice")
    }

    @Test func theCaptionRowDrawsTheVoiceAndItsWordsUnderIt() {
        let previous = CaptionBubbleCell.playbackHub
        CaptionBubbleCell.playbackHub = hub()
        defer { CaptionBubbleCell.playbackHub = previous }

        let cell = CaptionBubbleCell()
        cell.configure(with: PostDetailDisplayModel(entry: entry(caption: "", voice: voice), showsVoice: true),
                       imagePipeline: nil)
        let view = try? #require(cell.debugVoiceView)
        #expect(view?.size == .full)
        #expect(view?.debugTimerText == "12\u{2033}", "a voice post's seconds (#2294)")
        #expect(view?.accessibilityLabel == "Voice post by Ava Moreau, 13 seconds")
        #expect(!cell.debugShowsBody, "an empty line under a voice alone")

        cell.configure(with: PostDetailDisplayModel(entry: entry(caption: "From the ridge", voice: voice), showsVoice: true),
                       imagePipeline: nil)
        #expect(cell.debugVoiceView != nil && cell.debugShowsBody)

        // A plain text post, and a voice post with the flag off: today's row.
        cell.configure(with: PostDetailDisplayModel(entry: entry(caption: "Just words", voice: nil), showsVoice: true),
                       imagePipeline: nil)
        #expect(cell.debugVoiceView == nil && cell.debugShowsBody)
        cell.configure(with: PostDetailDisplayModel(entry: entry(caption: "Words", voice: voice), showsVoice: false),
                       imagePipeline: nil)
        #expect(cell.debugVoiceView == nil)
    }

    /// The row is measured with the voice: no jump when it lands.
    @Test func theRowIsMeasuredWithTheVoice() {
        func height(_ voice: PostVoice?) -> CGFloat {
            let cell = CaptionBubbleCell()
            cell.configure(with: PostDetailDisplayModel(entry: entry(caption: "From the ridge", voice: voice), showsVoice: true),
                           imagePipeline: nil)
            cell.bounds.size.width = 390
            cell.contentView.layoutIfNeeded()
            return cell.contentView.systemLayoutSizeFitting(
                CGSize(width: 390, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height
        }
        #expect(height(voice) > height(nil) + 20, "the voice took no room")
    }

    // MARK: - Playback

    /// Keyed by the post: a tap plays "post-<id>"; the row leaving the
    /// window stops it where it was.
    @Test func itPlaysByPostAndStopsWhenTheRowLeaves() throws {
        let hub = hub()
        let previous = CaptionBubbleCell.playbackHub
        CaptionBubbleCell.playbackHub = hub
        defer { CaptionBubbleCell.playbackHub = previous }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        defer { window.isHidden = true }
        let cell = CaptionBubbleCell(frame: CGRect(x: 0, y: 0, width: 402, height: 200))
        window.addSubview(cell)
        cell.configure(with: PostDetailDisplayModel(entry: entry(caption: "", voice: voice), showsVoice: true),
                       imagePipeline: nil)
        #expect(cell.shownVoiceID == "post-p-voice")
        try #require(cell.debugVoiceView).debugTapPlay()
        #expect(hub.isPlaying("post-p-voice"))
        cell.removeFromSuperview()
        #expect(!hub.isPlaying("post-p-voice"), "the voice went on after its page left")
    }
}
