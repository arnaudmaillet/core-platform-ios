import AVFoundation
import DesignSystem
import Testing
import UIKit
@testable import VoiceKit
@testable import VoiceKitUI

/// The shared voice component (#2205): three sizes of one view, its ink
/// from its host, one voice at a time for every view on an id.
@MainActor
struct VoiceComponentTests {
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

    final class Engines { var all: [Engine] = [] }

    let center = NotificationCenter()
    let url = URL(fileURLWithPath: "/tmp/voice.m4a")

    private func hub(_ engines: Engines) -> VoicePlaybackHub {
        let name = "voice-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let player = VoicePlayer(session: Session(), makeEngine: {
            let engine = Engine()
            engines.all.append(engine)
            return engine
        }, defaults: defaults, notifications: center)
        return VoicePlaybackHub(player: player, notifications: center)
    }

    // MARK: - Sizes

    /// Full scrubs; compact keeps the tap and gives every drag to its
    /// shelf; both play.
    @Test func fullScrubsCompactOnlyTaps() {
        let full = VoiceView(size: .full)
        let compact = VoiceView(size: .compact)
        #expect(full.waveform.scrubs && full.debugSideHoldEnabled && full.debugPlayHoldEnabled)
        #expect(!compact.waveform.scrubs, "a drag on a compact waveform would fight the shelf's scroll")
        #expect(!compact.debugSideHoldEnabled && !compact.debugPlayHoldEnabled)
        let taps = compact.waveform.gestureRecognizers?.filter { $0 is UITapGestureRecognizer && $0.isEnabled } ?? []
        #expect(!taps.isEmpty, "a compact waveform no longer seeks on a tap")
        for view in [full, compact] {
            view.configure(VoiceView.State(levels: VoiceView.genericLevels, duration: 32))
            #expect(view.debugPlayEnabled)
            #expect(view.debugTimerText == "0:32")
        }
    }

    /// A tap on a compact waveform seeks: its seek reaches the host.
    @Test func aCompactTapSeeks() {
        let compact = VoiceView(size: .compact)
        compact.configure(VoiceView.State(levels: VoiceView.genericLevels, duration: 10))
        var seeks: [Double] = []
        compact.onSeek = { fraction, scrubbing in
            #expect(!scrubbing)
            seeks.append(fraction)
        }
        compact.waveform.onSeek?(0.5, false)
        #expect(seeks == [0.5])
    }

    /// The mark draws a mic, still bars and the length, and takes no touch.
    @Test func theMarkDoesNotPlay() {
        let mark = VoiceMarkView()
        mark.configure(duration: 32, levels: nil)
        #expect(!mark.isUserInteractionEnabled, "a tap on a tile's mark must open the post")
        #expect(!mark.isAccessibilityElement, "the mark is read as part of its tile")
        #expect(mark.debugDurationText == "0:32")
        #expect(mark.debugBarCount == VoiceMarkView.barCount)
        #expect(mark.accessibilityDescription == "Voice post, 32 seconds")
        #expect(mark.subviews.allSatisfy { !($0 is UIControl) })
    }

    /// The bare play glyph keeps a 44 pt target round its 32 pt compact frame.
    @Test func thePlayButtonKeepsA44PointTarget() {
        let voice = VoiceView(size: .compact)
        voice.configure(VoiceView.State(levels: nil, duration: 5))
        let button = voice.debugPlayButton
        let side = VoiceView.buttonSide(for: .compact)
        button.frame = CGRect(x: 0, y: 0, width: side, height: side)
        button.layoutIfNeeded()
        let edge = (44 - side) / 2
        #expect(button.point(inside: CGPoint(x: -edge + 0.5, y: side / 2), with: nil))
        #expect(!button.point(inside: CGPoint(x: -edge - 2, y: side / 2), with: nil))
    }

    /// The ink is the host's.
    @Test func theInkFollowsItsGround() {
        let voice = VoiceView(size: .full)
        let inks = VoiceView.Inks(played: .white, unplayed: .white.withAlphaComponent(0.4), timer: .white)
        voice.inks = inks
        #expect(voice.waveform.playedInk == .white)
        #expect(voice.waveform.unplayedInk == inks.unplayed)
        #expect(voice.debugTimerInk == .white)
        // The panel's ground follows the ink too (#2241).
        #expect(rgba(voice.debugPanelFill, .light) == rgba(UIColor(white: 1, alpha: VoiceView.Inks.panelOpacityLight), .light))
        let mark = VoiceMarkView()
        mark.ink = .systemPink
        #expect(mark.ink == .systemPink)
    }

    // MARK: - One voice, every view

    /// Two views on one id show the same progress; a voice started on one
    /// goes on, at the same place, on the other.
    @Test func twoViewsOnOneIdShareTheProgress() {
        let engines = Engines()
        let hub = hub(engines)
        let card = VoiceView(size: .compact)
        let page = VoiceView(size: .full)
        let other = VoiceView(size: .compact)
        hub.bind(card, id: "post-1", url: url, duration: 10, levels: nil)
        hub.bind(page, id: "post-1", url: url, duration: 10, levels: nil)
        hub.bind(other, id: "post-2", url: url, duration: 10, levels: nil)

        card.onPlayTap?()
        #expect(hub.isPlaying("post-1"))
        engines.all.last?.currentTime = 4
        hub.seek("post-1", to: 0.4)
        #expect(card.state.playback == .playing(progress: 0.4))
        #expect(page.state.playback == card.state.playback, "the page doesn't show where the card is")
        #expect(other.state.playback == .rest, "another post moved with it")

        // Paused on the page, both say paused at the same place.
        page.onPlayTap?()
        #expect(card.state.playback == .paused(progress: 0.4))
        #expect(page.state.playback == .paused(progress: 0.4))
    }

    /// Stopped (its card left the screen), a voice keeps its place.
    @Test func aStoppedVoiceKeepsItsPlace() {
        let engines = Engines()
        let hub = hub(engines)
        let card = VoiceView(size: .compact)
        hub.bind(card, id: "post-1", url: url, duration: 10, levels: nil)
        hub.toggle("post-1")
        engines.all.last?.currentTime = 6
        hub.stop("post-1")
        #expect(!hub.isPlaying("post-1"))
        #expect(card.state.playback == .paused(progress: 0.6))
        hub.toggle("post-1")
        #expect(engines.all.last?.currentTime == 6, "it started again from the start")
    }

    // MARK: - VoiceOver

    @Test func voiceOverReadsAPostAndAMessage() {
        #expect(VoiceView.accessibilityLabel(role: .post(author: "Ava"), senderName: nil, duration: 32, unplayed: false)
            == "Voice post by Ava, 32 seconds")
        #expect(VoiceView.accessibilityLabel(role: .post(author: nil), senderName: nil, duration: 1, unplayed: false)
            == "Voice post, 1 second")
        #expect(VoiceView.accessibilityLabel(role: .message, senderName: "Ava", duration: 12, unplayed: true)
            == "Voice message from Ava, 12 seconds, not played")
        let voice = VoiceView(size: .compact)
        voice.role = .post(author: "Ava")
        voice.configure(VoiceView.State(levels: nil, duration: 32))
        #expect(voice.accessibilityLabel == "Voice post by Ava, 32 seconds")
        #expect(voice.accessibilityTraits.contains(.adjustable), "seek is not an adjustable value")
        #expect(voice.accessibilityCustomActions?.map(\.name).contains("Play") == true)
    }

    @Test func theGenericWaveformHasAShape() {
        #expect(VoiceView.genericLevels.count == 100)
        #expect(Set(VoiceView.genericLevels).count > 5)
        #expect(VoiceView.genericLevels.allSatisfy { $0 <= 31 })
    }
}
