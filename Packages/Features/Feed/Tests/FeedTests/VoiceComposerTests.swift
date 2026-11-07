import AVFoundation
import FeedInterface
import Testing
import UIKit
import VoiceKit
@testable import Feed

/// Recording from the composer (#2102), over #2101's recorder with a fake
/// device: no microphone.
@MainActor
struct VoiceComposerTests {
    final class Session: VoiceAudioSessionControlling {
        var isInputAvailable = true
        func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {}
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
    }

    final class Permission: VoiceMicrophonePermission {
        var state: VoicePermissionState
        init(_ state: VoicePermissionState) { self.state = state }
        func request() async -> Bool { state = .granted; return true }
    }

    final class Device: VoiceRecordingDevice {
        var currentTime: TimeInterval = 0
        private(set) var pauses = 0
        func prepare(writingTo url: URL) throws {
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        }
        func record() -> Bool { true }
        func pause() { pauses += 1 }
        func stop() {}
        func meter() -> (average: Float, peak: Float) { (-20, -10) }
    }

    final class Ticker: VoiceTicking {
        func start(interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {}
        func stop() {}
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 0)
    }

    let device = Device()
    let clock = Clock()

    func composer(_ permission: VoicePermissionState = .granted, key: String = "conv-\(UUID().uuidString)")
        -> (VoiceComposer, CommentsInputBar, Sent) {
        let fake = device
        let recorder = VoiceRecorder(
            session: Session(), permission: Permission(permission), makeDevice: { fake }, ticker: Ticker(),
            notifications: NotificationCenter(), keepAwake: { _ in }
        )
        let time = clock
        let composer = VoiceComposer(recorder: recorder, draftKey: key, now: { time.now })
        let bar = CommentsInputBar()
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host.addSubview(bar)
        composer.attach(to: bar, host: host)
        let sent = Sent()
        composer.onSend = { sent.takes.append($0) }
        composer.onHint = { sent.hints.append($0) }
        composer.onPermissionDenied = { sent.denied += 1 }
        return (composer, bar, sent)
    }

    final class Sent {
        var takes: [ConversationThreadVoiceTake] = []
        var hints: [String] = []
        var denied = 0
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Hold, wait past 200 ms, release: sent.
    @Test func holdThenReleaseSends() async {
        let (composer, bar, sent) = composer()
        #expect(bar.holdsToRecord)
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) }, "the strip never showed")
        #expect(bar.voiceOverlay === composer.debugStrip)
        device.currentTime = 3
        clock.now += 3
        composer.handle(.ended(leading: 0))
        #expect(sent.takes.count == 1)
        #expect(sent.takes.first?.duration == 3)
        #expect(composer.phase == .idle)
        #expect(bar.voiceOverlay == nil, "the field was not given back")
    }

    /// A quick lift is a tap: the hint, nothing recorded or sent.
    @Test func aTapShowsTheHint() async {
        let (composer, _, sent) = composer()
        composer.handle(.began)
        clock.now += 0.1
        composer.handle(.ended(leading: 0))
        #expect(await settle { sent.hints == [VoiceComposer.hint] })
        #expect(sent.takes.isEmpty)
        #expect(composer.phase == .idle)
    }

    /// Held, but under a second of sound: refused, with the hint.
    @Test func underASecondIsNotSent() async {
        let (composer, _, sent) = composer()
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        device.currentTime = 0.6
        clock.now += 0.6
        composer.handle(.ended(leading: 0))
        #expect(sent.takes.isEmpty)
        #expect(sent.hints == [VoiceComposer.hint])
    }

    /// Slid 100 pt toward the leading edge: cancelled, nothing sent.
    @Test func slidingAwayCancels() async {
        let (composer, _, sent) = composer()
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        device.currentTime = 4
        composer.handle(.moved(leading: 100, up: 0))
        #expect(composer.phase == .idle)
        composer.handle(.ended(leading: 100))
        #expect(sent.takes.isEmpty)
    }

    /// Slid up past the lock: the finger is free; pause, then ↑ sends once.
    @Test func lockPauseThenSend() async {
        let (composer, bar, sent) = composer()
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        composer.handle(.moved(leading: 0, up: 101))
        #expect(composer.phase == .locked)
        composer.handle(.ended(leading: 0))
        #expect(composer.phase == .locked, "lifting the finger after the lock ended the take")
        #expect(composer.debugStrip.debugVisibleControls == ["Pause recording", "Send voice message"])
        #expect(composer.debugStrip.debugShowsWaveform, "locked, the bars fill the field")
        #expect(bar.debugShowsVoiceDelete, "the bin stands in the avatar's place")
        composer.debugStrip.debugTap("Pause recording")
        #expect(composer.phase == .paused(resumable: true))
        #expect(device.pauses == 1)
        #expect(composer.debugStrip.debugVisibleControls == ["Play recording", "Resume recording", "Send voice message"],
                "paused, the chip plays the take back")
        #expect(bar.debugShowsVoiceDelete)
        device.currentTime = 7
        composer.debugStrip.debugTap("Send voice message")
        #expect(sent.takes.count == 1)
        #expect(bar.voiceOverlay == nil)
        #expect(!bar.debugShowsVoiceDelete, "the face is back")
    }

    /// Held, the action bubble itself grows into the mic, wears the bin
    /// once the finger slides toward cancel, and — cancelled — goes back to
    /// its place, size and waveform (the owner, 2026-11-07).
    @Test func theBubbleGrowsIntoTheMicAndComesBack() async {
        let (composer, bar, _) = composer()
        // In a window: the bubble animates its way back, as on screen.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        bar.actsFromOwnBubble = true
        bar.layoutIfNeeded()
        let bubble = bar.debugRowActionButton
        let rest = bubble.frame
        bubble.layoutIfNeeded()
        let restSymbol = bubble.imageView?.frame.size ?? .zero
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        bar.layoutIfNeeded()
        #expect(bar.isVoiceHolding)
        #expect(abs(bubble.frame.width - CommentsInputBar.voiceHoldSide) < 0.5, "\(bubble.frame)")
        #expect(abs(bubble.frame.midX - rest.midX) < 0.5 && abs(bubble.frame.midY - rest.midY) < 0.5,
                "it grew about its own centre")
        let glyph = bar.debugHoldGlyph
        #expect(!glyph.isHidden && glyph.image != nil, "no mic on the held bubble")
        // Within a point: the symbol's own frame rounds to the pixel.
        #expect(abs(glyph.frame.midX - bubble.frame.midX) < 1 && abs(glyph.frame.midY - bubble.frame.midY) < 1,
                "the mic is off the bubble's centre: \(glyph.frame) \(bubble.frame)")
        device.currentTime = 4
        composer.handle(.moved(leading: 40, up: 0))
        bar.layoutIfNeeded()
        #expect(bubble.frame.midX < rest.midX, "the bubble did not follow the finger")
        #expect(abs(glyph.frame.midX - bubble.frame.midX) < 1, "the glyph drifted off centre as the bubble moved")
        #expect(bubble.tintColor == .systemRed, "no bin on the way to cancel")
        composer.handle(.moved(leading: 100, up: 0))
        #expect(composer.phase == .idle)
        bar.layoutIfNeeded()
        #expect(!bar.isVoiceHolding)
        #expect(bubble.frame == rest, "the bubble did not come back: \(bubble.frame) vs \(rest)")
        #expect(bubble.tintColor != .systemRed, "the bubble kept the bin's red")
        // The waveform rides home on the bar's glyph, centred all the way —
        // handed to the button in the big bubble, it came back from the
        // corner (filmed, 2026-11-07) — and the button takes it once landed.
        #expect(!glyph.isHidden, "the waveform did not ride home on the glyph")
        if !glyph.isHidden {
            #expect(bubble.configuration?.image == nil, "two waveforms on the way back")
            // The button's own size, or the waveform jumps at the hand-over
            // (the width: the button's image box is a text line tall).
            let size = glyph.intrinsicContentSize
            #expect(abs(size.width - restSymbol.width) < 1,
                    "the waveform comes back at \(size), the button draws it at \(restSymbol)")
            #expect(abs(glyph.frame.midX - bubble.frame.midX) < 1 && abs(glyph.frame.midY - bubble.frame.midY) < 1,
                    "the waveform left the bubble's centre on the way back")
        }
        #expect(await settle { glyph.isHidden }, "the held glyph stayed")
        #expect(bubble.configuration?.image?.isSymbolImage == true, "the button never took the waveform back")
    }

    /// Locked, the bubble steps aside wearing the mic: no waveform shows
    /// over the take's send on its way out (filmed, 2026-11-07), and it
    /// comes back with its waveform once the take is gone.
    @Test func theLockedBubbleLeavesWearingTheMic() async {
        let (composer, bar, _) = composer()
        // In a window: the bubble animates its way back, as on screen.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        bar.actsFromOwnBubble = true
        bar.layoutIfNeeded()
        let bubble = bar.debugRowActionButton
        let glyph = bar.debugHoldGlyph
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        let mic = glyph.image
        composer.handle(.moved(leading: 0, up: 101))
        #expect(composer.phase == .locked)
        #expect(bubble.configuration?.image == nil, "the leaving bubble wears the waveform")
        #expect(!glyph.isHidden && glyph.image == mic, "the leaving glyph turned to the waveform")
        #expect(await settle { glyph.isHidden }, "the held glyph stayed")
        bar.debugTapVoiceDelete()
        #expect(await settle { composer.phase == .idle })
        #expect(await settle { bar.debugShowsRowAction }, "the bubble never came back")
        #expect(bubble.configuration?.image?.isSymbolImage == true, "the bubble came back bare")
    }

    /// The bin in the avatar's place throws the locked take away.
    @Test func theBinInTheAvatarsPlaceThrowsTheTakeAway() async {
        let (composer, bar, sent) = composer()
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        #expect(!bar.debugShowsVoiceDelete, "held, the slide cancels: no bin yet")
        composer.handle(.moved(leading: 0, up: 101))
        composer.handle(.ended(leading: 0))
        #expect(bar.debugShowsVoiceDelete)
        bar.debugTapVoiceDelete()
        #expect(composer.phase == .idle)
        #expect(sent.takes.isEmpty)
        #expect(!bar.debugShowsVoiceDelete)
    }

    /// A take that fills the bars never squeezes the buttons: the pause
    /// keeps its size beside the send (the owner's video, 2026-11-07).
    @Test func fullBarsNeverSqueezeTheButtons() {
        let strip = VoiceRecordingStrip(frame: CGRect(x: 0, y: 0, width: 280, height: 44))
        strip.apply(.locked)
        strip.layoutIfNeeded()
        for _ in 0..<120 {
            strip.appendLevel(0.4)
            strip.layoutIfNeeded()
        }
        let take = strip.debugTakeFrame, send = strip.debugSendFrame
        #expect(!take.intersects(send), "\(take) under \(send)")
        #expect(take.width >= 26, "the pause was squeezed: \(take)")
        #expect(strip.debugWaveformFrame.maxX <= take.minX, "the bars run under the pause")
    }

    /// Locked or paused, the time leads the field on its chip and the bars
    /// fill the rest (the owner, 2026-11-07).
    @Test func theTimeLeadsTheFieldOnItsChip() {
        let strip = VoiceRecordingStrip(frame: CGRect(x: 0, y: 0, width: 260, height: 44))
        strip.apply(.paused(resumable: true, playing: false))
        strip.setTime(42, remaining: nil)
        strip.layoutIfNeeded()
        let chip = strip.debugChipFrame, bars = strip.debugWaveformFrame
        #expect(strip.debugTimerText == "0:42")
        #expect(chip.minX < 1, "the chip leads the field: \(chip)")
        #expect(bars.minX >= chip.maxX, "\(bars) after \(chip)")
        #expect(bars.width > 90, "the bars fill the rest: \(bars)")
        #expect(abs(chip.midY - bars.midY) < 0.5)
        strip.apply(.recording)
        #expect(!strip.debugShowsWaveform, "held: the dot, the time and the hint")
    }

    /// Refused before: a hold offers Settings, and records nothing.
    @Test func aDeniedMicrophoneOffersSettings() async {
        let (composer, _, sent) = composer(.denied)
        composer.handle(.began)
        #expect(await settle { sent.denied == 1 })
        #expect(composer.phase == .idle)
    }

    /// A locked take left behind is the conversation's draft for the app's
    /// session: coming back shows the paused bar.
    @Test func aLockedTakeIsKeptAsTheConversationsDraft() async {
        let key = "conv-draft-\(UUID().uuidString)"
        let (composer, _, _) = composer(key: key)
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        composer.handle(.moved(leading: 0, up: 101))
        device.currentTime = 5
        composer.leave()
        #expect(VoiceComposer.debugDraft(for: key)?.duration == 5)
        let (again, bar, _) = self.composer(key: key)
        #expect(again.phase == .paused(resumable: false))
        #expect(bar.voiceOverlay != nil)
        #expect(VoiceComposer.debugDraft(for: key) == nil, "the draft was shown and kept")
    }

    /// A post's comments keep today's tap: no hold.
    @Test func aPostsComposerKeepsTheTap() {
        let bar = CommentsInputBar()
        #expect(!bar.holdsToRecord)
    }
}
