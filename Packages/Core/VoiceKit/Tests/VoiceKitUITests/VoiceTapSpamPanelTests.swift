import AVFoundation
import DesignSystem
import Testing
import UIKit
@testable import VoiceKit
@testable import VoiceKitUI

/// Fast play / pause taps on the panel (#2414): the hub pauses a voice on
/// its way, the place stays drawn while it loads, and the timer ⇄ speed
/// swap is the play glyph's.
@MainActor
struct VoiceTapSpamPanelTests {
    /// A session that answers a play's claim only when told, as the
    /// system's does off the main thread (#2329).
    final class DeferredSession: VoiceAudioSessionControlling {
        var isInputAvailable = true
        private var pending: [@MainActor @Sendable ((any Error)?) -> Void] = []
        func setCategory(
            _ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
        ) throws {}
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
        func setAllowHapticsAndSystemSoundsDuringRecording(_ allow: Bool) throws {}
        func activate(
            _ role: VoiceSessionRole, then completion: @escaping @MainActor @Sendable ((any Error)?) -> Void
        ) {
            pending.append(completion)
        }

        func answer() {
            let waiting = pending
            pending = []
            for completion in waiting { completion(nil) }
        }
    }

    /// A pause's grace, run out when the test says.
    final class Grace: VoiceTicking {
        private var tick: (@MainActor () -> Void)?
        func start(interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) { self.tick = tick }
        func stop() { tick = nil }
        func runOut() { tick?() }
    }

    final class Engine: VoicePlaybackEngine {
        var onEnd: (() -> Void)?
        var onFailure: (() -> Void)?
        var currentTime: TimeInterval = 0
        var duration: TimeInterval? = 10
        private(set) var loads = 0
        func load(_ url: URL) { loads += 1 }
        func play(rate: Float) {}
        func pause() {}
        func seek(to seconds: TimeInterval) { currentTime = seconds }
    }

    final class Engines { var all: [Engine] = [] }

    let center = NotificationCenter()
    let url = URL(fileURLWithPath: "/tmp/voice.m4a")
    let session = DeferredSession()
    let grace = Grace()

    private func hub(_ engines: Engines) -> VoicePlaybackHub {
        let name = "voice-tap-spam-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let player = VoicePlayer(session: session, makeEngine: {
            let engine = Engine()
            engines.all.append(engine)
            return engine
        }, defaults: defaults, notifications: center, graceTimer: grace)
        return VoicePlaybackHub(player: player, notifications: center)
    }

    /// A tap on a voice on its way pauses it, keeping its place — the
    /// hub's toggle used to start it again, from a place remembered at an
    /// older pause or from 0 — and while it loads the panel keeps the
    /// place drawn: the played bars, the time reached.
    @Test func aTapWhileLoadingPausesWithThePlaceDrawn() throws {
        let engines = Engines()
        let hub = hub(engines)
        let view = VoiceView(size: .full)
        hub.bind(view, id: "post-1", url: url, duration: 10, levels: nil)

        hub.toggle("post-1")
        #expect(view.state.playback == .loading(progress: 0), "a first play from the start is at 0")
        session.answer()
        let engine = try #require(engines.all.first)
        engine.currentTime = 4
        hub.toggle("post-1")
        #expect(view.state.playback == .paused(progress: 0.4))
        grace.runOut()

        hub.toggle("post-1")
        #expect(view.state.playback == .loading(progress: 0.4), "loading dropped the place")
        #expect(view.state.isUnderway && view.state.progress == 0.4)
        hub.toggle("post-1")
        #expect(view.state.playback == .paused(progress: 0.4), "a tap while it loads didn't pause it")
        #expect(engines.all.count == 1 && engine.loads == 1, "a tap while it loads loaded the file again")

        hub.toggle("post-1")
        session.answer()
        #expect(view.state.playback == .playing(progress: 0.4), "the resume moved the place")
        #expect(engines.all.count == 1)
    }

    /// While it loads from a place, the timer reads the time reached, not
    /// the length; from the start, the length (the slot shows the speed
    /// meanwhile either way).
    @Test func loadingFromAPlaceReadsTheTimeReached() {
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 34)
        state.playback = .loading(progress: 0.5)
        #expect(state.isUnderway && state.isLoading && state.progress == 0.5)
        state.playback = .loading(progress: 0)
        #expect(!state.isUnderway && state.isLoading && state.progress == 0)
        #expect(VoiceView.slotContent(for: .loading(progress: 0.5)) == .speed)
    }

    /// The slot's swap is the glyph's, read from `PlayPauseGlyph`: the same
    /// scale, leave and arrive — the arriving words on the very spring the
    /// glyph springs on.
    @Test func theSlotSwapReadsTheGlyphsTimings() throws {
        #expect(VoiceView.slotSwapScale == PlayPauseGlyph.swapScale)
        #expect(VoiceView.slotLeaveDuration == PlayPauseGlyph.leaveDuration)
        #expect(VoiceView.slotArriveDuration == PlayPauseGlyph.arriveDuration)
        #expect(VoiceView.slotArriveDelay == PlayPauseGlyph.arriveDelay)
        #expect(VoiceView.slotArriveDamping == PlayPauseGlyph.arriveDamping)
        #expect(VoiceView.slotCrossFadeDuration == PlayPauseGlyph.crossFadeDuration)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        let view = VoiceView(size: .full)
        view.reducesMotion = { false }
        view.frame = CGRect(x: 0, y: 0, width: 340, height: 80)
        window.addSubview(view)
        var state = VoiceView.State(levels: VoiceView.genericLevels, duration: 12)
        view.configure(state)
        view.layoutIfNeeded()

        // The glyph's arrive, as UIKit builds it, for comparison.
        let reference = UIView()
        window.addSubview(reference)
        reference.alpha = 0
        UIView.animate(
            withDuration: PlayPauseGlyph.arriveDuration, delay: PlayPauseGlyph.arriveDelay,
            usingSpringWithDamping: PlayPauseGlyph.arriveDamping, initialSpringVelocity: 0, options: [.allowUserInteraction]
        ) {
            reference.alpha = 1
        }
        let glyphs = try #require(reference.layer.animation(forKey: "opacity") as? CASpringAnimation)

        state.playback = .playing(progress: 0.2)
        view.update(state)
        #expect(view.debugSlotMotion == .scaleAndFade)
        let arriving = try #require(view.debugSpeedOpacityAnimation as? CASpringAnimation, "the speed doesn't spring in")
        #expect(abs(arriving.damping - glyphs.damping) < 1e-6 && abs(arriving.stiffness - glyphs.stiffness) < 1e-6)
        #expect(arriving.duration == glyphs.duration)
        let leaving = try #require(view.debugTimerOpacityDuration)
        #expect(abs(leaving - PlayPauseGlyph.leaveDuration) < 0.001)
        reference.layer.removeAllAnimations()
        view.removeFromSuperview()
    }
}
