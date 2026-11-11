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

    func composer(
        _ permission: VoicePermissionState = .granted, key: String = "conv-\(UUID().uuidString)",
        join: ((VoiceDraft, VoiceDraft) async throws -> VoiceDraft)? = nil
    ) -> (VoiceComposer, CommentsInputBar, Sent) {
        let fake = device
        let recorder = VoiceRecorder(
            session: Session(), permission: Permission(permission), makeDevice: { fake }, ticker: Ticker(),
            notifications: NotificationCenter(), keepAwake: { _ in }
        )
        let time = clock
        let composer = VoiceComposer(
            recorder: recorder, draftKey: key, now: { time.now },
            join: join ?? { first, second in
                VoiceDraft(fileURL: first.fileURL, duration: first.duration + second.duration, waveform: first.waveform)
            }
        )
        let bar = CommentsInputBar()
        // A conversation's contract: its field records a message (#2308).
        bar.configuration = .conversation(voice: .message, attachments: [])
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
        #expect(bar.speaksFromField)
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

    /// "Hold for voice, tap to type" (the owner, 2026-11-07): in a
    /// conversation the field says so, its long press records, and the
    /// bubble at rest is the emote button — the field's own goes until
    /// there is a draft, and comes back beside the send.
    @Test func theFieldSpeaksAndTheBubbleIsTheEmoteButton() async {
        let (composer, bar, _) = composer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        bar.layoutIfNeeded()
        let bubble = bar.debugRowActionButton
        #expect(bar.speaksFromField)
        #expect(bar.debugPlaceholder == CommentsInputBar.speakOrWritePlaceholder)
        #expect(bubble.accessibilityLabel == "Emotes")
        #expect(!bar.debugShowsFieldEmoteToggle, "two emote buttons at rest")
        #expect(bar.debugFieldHoldBegins, "the field's hold does not record")
        #expect(bubble.gestureRecognizers?.contains { $0 is UILongPressGestureRecognizer } != true,
                "the emote bubble still carries a voice hold")

        // A tap on the bubble: the panel, and the bubble offers the keyboard back.
        bubble.sendActions(for: .primaryActionTriggered)
        #expect(bar.debugShowsEmotePanel)
        #expect(bubble.accessibilityLabel == "Keyboard")
        bubble.sendActions(for: .primaryActionTriggered)
        #expect(!bar.debugShowsEmotePanel)
        #expect(composer.phase == .idle, "the bubble's tap recorded")

        // A draft: the send in the bubble, the emote button back in the field.
        bar.draftText = "hi"
        bar.layoutIfNeeded()
        #expect(bubble.accessibilityLabel != "Emotes" && bubble.accessibilityLabel != "Keyboard")
        #expect(bar.debugShowsFieldEmoteToggle, "no emote button beside the send")
        #expect(!bar.debugFieldHoldBegins, "a draft's long press recorded")
        bar.draftText = ""
        #expect(!bar.debugShowsFieldEmoteToggle)
    }

    /// The field's instructions stand centred in it (the owner, 2026-11-07);
    /// a reply's wording goes back to the text's start.
    @Test func theInstructionsAreCentred() {
        let (_, bar, _) = composer()
        bar.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        bar.layoutIfNeeded()
        let field = bar.debugFieldBounds
        let words = bar.debugPlaceholderFrame
        #expect(abs(words.midX - field.midX) < 1, "\(words) in \(field)")
    }

    /// The strip is laid out the moment it shows, before the bubble's grow
    /// spring: its parts no longer fly in from the field's top-left corner
    /// (the owner, 2026-11-07).
    @Test func theStripIsLaidOutTheMomentItShows() {
        let bar = CommentsInputBar()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        bar.frame = CGRect(x: 0, y: 700, width: 390, height: 120)
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        bar.layoutIfNeeded()
        let strip = VoiceRecordingStrip()
        strip.setTime(0, remaining: nil) // as the composer does, before it shows
        bar.showVoiceOverlay(strip)
        #expect(strip.bounds.width > 0 && strip.bounds.height > 0, "the strip waits for a later pass: \(strip.frame)")
        #expect(strip.debugTimerFrame.width > 0, "the time waits for a later pass")
    }

    /// Locked in sight, the strip springs from the hint to the bars and its
    /// buttons, and ends on the locked bar's parts.
    @Test func aLockInSightEndsOnTheLockedBar() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        window.isHidden = false
        defer { window.isHidden = true }
        let strip = VoiceRecordingStrip(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        window.addSubview(strip)
        strip.layoutIfNeeded()
        strip.apply(.locked, animated: true)
        #expect(strip.debugShowsWaveform)
        #expect(strip.debugVisibleControls == ["Pause recording", "Send voice message"])
        #expect(await settle { strip.debugTimerFrame.width == 0 || strip.debugHidesTimer }, "the hint's time stayed")
    }

    /// The lock leaves once the take is locked — after its way out, not at
    /// once — and the next hold's lock is not taken away by it.
    @Test func theLockLeavesAndANewHoldKeepsItsOwn() async {
        let (composer, bar, _) = composer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        bar.frame = CGRect(x: 0, y: 700, width: 390, height: 120)
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        // The window is the host the lock rises in (the helper's own is gone).
        composer.attach(to: bar, host: window)
        bar.layoutIfNeeded()
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        #expect(composer.debugLock.superview != nil)
        composer.handle(.moved(leading: 0, up: 101))
        #expect(composer.phase == .locked)
        #expect(await settle { composer.debugLock.superview == nil }, "the lock stayed")
    }

    /// VoiceOver records from the field's own action — holding is
    /// impractical, and the bubble is the emote button.
    @Test func voiceOverRecordsFromTheField() async {
        let (composer, bar, _) = composer()
        let action = bar.debugTextView.accessibilityCustomActions?.first { $0.name == "Record voice message" }
        #expect(action != nil)
        if let action { _ = action.actionHandler?(action) }
        #expect(await settle { composer.phase != .idle }, "VoiceOver's action recorded nothing")
    }

    /// A post's comments (#2308): the same own bubble — the emote button at
    /// rest — and no voice: the field's hold records nothing, and nothing
    /// promises it (no instructions, no VoiceOver action).
    @Test func aPostsFieldHasTheOwnBubbleAndNoVoice() {
        let bar = CommentsInputBar()
        bar.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        bar.onVoiceHold = { _ in }
        bar.layoutIfNeeded()
        #expect(bar.configuration.voice == .none)
        #expect(!bar.speaksFromField)
        #expect(!bar.debugFieldHoldBegins, "a comment's field records")
        #expect(bar.debugRowActionButton.accessibilityLabel == "Emotes")
        #expect(!bar.debugShowsFieldEmoteToggle, "two emote buttons at rest")
        #expect(bar.debugPlaceholder != CommentsInputBar.speakOrWritePlaceholder)
        #expect(bar.debugTextView.accessibilityCustomActions == nil)
    }

    final class Joins {
        var pairs: [[TimeInterval]] = []
    }

    /// Listened back, the take is closed — and the 🎙 stays: it records on
    /// from the take's end, and the two parts go as one (the owner,
    /// 2026-11-08).
    @Test func afterAListenBackTheMicRecordsOnAndBothPartsGoAsOne() async {
        let joins = Joins()
        let (composer, _, sent) = composer(join: { first, second in
            joins.pairs.append([first.duration, second.duration])
            return VoiceDraft(fileURL: first.fileURL, duration: first.duration + second.duration, waveform: first.waveform)
        })
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        composer.handle(.moved(leading: 0, up: 101))
        composer.handle(.ended(leading: 0))
        device.currentTime = 3
        composer.debugStrip.debugTap("Pause recording")
        composer.debugStrip.debugTap("Play recording")
        #expect(composer.phase == .paused(resumable: false), "the listen back did not close the take")
        #expect(composer.debugStrip.debugVisibleControls.contains("Record more"), "the mic left after the listen back")
        composer.debugStrip.debugTap("Record more")
        #expect(await settle { composer.phase == .locked }, "the mic did not record on")
        device.currentTime = 2
        composer.debugStrip.debugTap("Send voice message")
        #expect(await settle { sent.takes.count == 1 }, "nothing was sent")
        #expect(joins.pairs == [[3, 2]], "the two parts were not joined, first then second")
        #expect(sent.takes.first?.duration == 5)
    }

    /// A second part under a second is dropped: the part before is sent.
    @Test func aRecordOnUnderASecondSendsThePartBefore() async {
        let joins = Joins()
        let (composer, _, sent) = composer(join: { first, second in
            joins.pairs.append([first.duration, second.duration])
            return first
        })
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        composer.handle(.moved(leading: 0, up: 101))
        device.currentTime = 4
        composer.debugStrip.debugTap("Pause recording")
        composer.debugStrip.debugTap("Play recording")
        composer.debugStrip.debugTap("Record more")
        #expect(await settle { composer.phase == .locked })
        device.currentTime = 0.4
        composer.debugStrip.debugTap("Send voice message")
        #expect(await settle { sent.takes.count == 1 })
        #expect(joins.pairs.isEmpty)
        #expect(sent.takes.first?.duration == 4)
    }

    /// The lock sinks back into the bubble it rose from (the owner,
    /// 2026-11-08: it rose on its way out).
    @Test func theLockSinksBackIntoTheBubble() async {
        let (composer, bar, _) = composer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        bar.frame = CGRect(x: 0, y: 700, width: 390, height: 120)
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        composer.attach(to: bar, host: window)
        bar.layoutIfNeeded()
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        let resting = composer.debugLock.center.y
        composer.handle(.moved(leading: 0, up: 101))
        #expect(composer.debugLock.superview != nil, "the lock left at once")
        #expect(composer.debugLock.transform.ty > 0, "the lock rose on its way out")
        #expect(composer.debugLock.center.y == resting)
    }

    /// Focused, the field writes: the host's placeholder at the text's start,
    /// and no voice hold or VoiceOver recording (the owner, 2026-11-08).
    @Test func aFocusedFieldWritesAndRecordsNothing() async throws {
        let (composer, bar, _) = composer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        bar.frame = CGRect(x: 0, y: 700, width: 390, height: 120)
        window.addSubview(bar)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        bar.defaultPlaceholder = "Message…"
        bar.layoutIfNeeded()
        #expect(bar.debugPlaceholder == CommentsInputBar.speakOrWritePlaceholder)
        #expect(bar.debugFieldHoldBegins)
        bar.debugTextView.becomeFirstResponder()
        try #require(bar.debugTextView.isFirstResponder, "the field took no focus")
        #expect(bar.debugPlaceholder == "Message…")
        #expect(bar.debugPlaceholderAlignment == .natural)
        #expect(!bar.debugFieldHoldBegins, "the focused field's long press records")
        #expect(bar.debugTextView.accessibilityCustomActions?.isEmpty ?? true, "VoiceOver still records from the focused field")
        bar.debugTextView.resignFirstResponder()
        #expect(bar.debugPlaceholder == CommentsInputBar.speakOrWritePlaceholder)
        #expect(bar.debugFieldHoldBegins)
        #expect(composer.phase == .idle)
    }

    /// ▶︎ to ❚❚, and ❚❚ to 🎙: only the faces change. The row does not spring
    /// (laid out in a spring, the chip's time flew in from its corner and
    /// the symbol's Replace stuttered under a moving frame: the owner's
    /// video, 2026-11-08), and the chip keeps its place and width though ▶︎,
    /// ❚❚ and ● are not the same width. A change that opens or closes the
    /// row still springs.
    @Test func aFaceChangeNeitherSpringsNorMovesTheChip() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        window.isHidden = false
        defer { window.isHidden = true }
        let strip = VoiceRecordingStrip(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        window.addSubview(strip)
        strip.apply(.locked)
        strip.setTime(6, remaining: nil)
        strip.layoutIfNeeded()
        strip.apply(.paused(resumable: true, playing: false), animated: true)
        #expect(strip.debugSpringCount == 0, "pausing sprang the row")
        let chip = strip.debugChipFrame
        strip.apply(.paused(resumable: false, playing: true), animated: true)
        strip.setTime(0, remaining: nil)
        strip.layoutIfNeeded()
        #expect(strip.debugSpringCount == 0, "playing back sprang the row")
        #expect(strip.debugChipFrame == chip, "the chip moved: \(strip.debugChipFrame) vs \(chip)")
        strip.apply(.recording, animated: true)
        #expect(strip.debugSpringCount == 1, "a change of parts no longer springs")
    }

    /// The bars cross-dissolve when they change source — the take listened
    /// back, then the take recording on — and redraw at once otherwise
    /// (the owner, 2026-11-08).
    @Test func theBarsCrossDissolveToAnotherSourceOnly() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        window.isHidden = false
        defer { window.isHidden = true }
        let strip = VoiceRecordingStrip(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        window.addSubview(strip)
        strip.apply(.locked)
        strip.layoutIfNeeded()
        strip.appendLevel(0.5)
        strip.appendLevel(0.6)
        #expect(strip.debugWaveformTransitions == 0, "the first bars or the same source dissolved")
        strip.apply(.paused(resumable: false, playing: false))
        strip.showTake(levels: Array(repeating: 12, count: 100), duration: 4, progress: 0)
        strip.showTake(levels: Array(repeating: 12, count: 100), duration: 4, progress: 0.5)
        #expect(strip.debugWaveformTransitions == 1, "live to the take did not dissolve once")
        strip.apply(.locked)
        strip.appendLevel(0.4)
        strip.appendLevel(0.3)
        #expect(strip.debugWaveformTransitions == 2, "the take to live did not dissolve once")
        // A new take starts from nothing: no dissolve into its first bars.
        strip.apply(.recording)
        strip.apply(.locked)
        strip.appendLevel(0.4)
        #expect(strip.debugWaveformTransitions == 2)
    }

    /// The emote button is a step larger, in the field and in the bubble
    /// (the owner, 2026-11-08), and its widest face fits the field's slot.
    @Test func theEmoteButtonIsLargerAndFitsItsSlot() throws {
        let small = try #require(UIImage(systemName: "face.smiling",
                                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium, scale: .large)))
        let keyboard = try #require(UIImage(systemName: "keyboard", withConfiguration: CommentsInputBar.emoteToggleConfiguration))
        let smile = try #require(UIImage(systemName: "face.smiling", withConfiguration: CommentsInputBar.emoteToggleConfiguration))
        #expect(smile.size.width > small.size.width, "the face is no larger than at 17 pt")
        #expect(max(keyboard.size.width, smile.size.width) <= CommentsInputBar.Metrics.emoteToggleWidth,
                "the widest face is \(max(keyboard.size.width, smile.size.width)) pt in a \(CommentsInputBar.Metrics.emoteToggleWidth) pt slot")
    }

    /// The field's emote button comes and goes in sight (the owner,
    /// 2026-11-08): a draft brings it in from half its size, fading in, as
    /// the field opens its slot; emptied, it leaves the same way and hides
    /// once out. A repeat of the same state does not animate again.
    @Test func theFieldsEmoteButtonComesAndGoesInMotion() async {
        let (_, bar, _) = composer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        bar.frame = CGRect(x: 0, y: 700, width: 390, height: 120)
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        bar.layoutIfNeeded()
        let toggle = bar.debugEmoteToggle
        #expect(toggle.isHidden, "an emote button in the empty field")
        let before = bar.debugEmoteToggleMotions
        bar.draftText = "hi"
        #expect(!toggle.isHidden, "the draft's emote button is not on its way in")
        // The slot is open before the scale starts: nothing swings from the edge.
        #expect(bar.debugEmoteSlotWidth == CommentsInputBar.Metrics.emoteToggleWidth, "the slot widens under the scale")
        #expect(toggle.bounds.width == CommentsInputBar.Metrics.emoteToggleWidth, "the button grows from the field's edge")
        #expect(bar.debugEmoteToggleMotions == before + 1, "the emote button came in with no motion")
        #expect(!(toggle.layer.animationKeys() ?? []).isEmpty, "nothing animates the emote button in")
        bar.draftText = "hi there"
        #expect(bar.debugEmoteToggleMotions == before + 1, "a longer draft animated it again")
        bar.draftText = ""
        #expect(bar.debugEmoteToggleMotions == before + 2, "the emote button left with no motion")
        #expect(!bar.debugShowsFieldEmoteToggle, "the emote button is not on its way out")
        #expect(await settle { toggle.isHidden }, "the emote button never hid once out")
        #expect(toggle.alpha == 1 && toggle.transform == .identity, "the emote button kept its way-out look")
        #expect(await settle { bar.debugEmoteSlotWidth == 0 }, "the slot never closed for the text")
    }

    /// ⚠️ A bar laid out for the first time inside an animation — a push,
    /// the keyboard — lays its buttons and glyphs out at once: they grew from
    /// a zero frame at the top-left corner (the owner, 2026-11-08: the emote
    /// button came in from there).
    @Test func aFirstLayoutInsideAnAnimationAnimatesNoButton() {
        let (_, bar, _) = composer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        defer { window.isHidden = true }
        bar.removeFromSuperview()
        bar.draftText = "hi"
        bar.frame = CGRect(x: 0, y: 700, width: 390, height: 120)
        window.addSubview(bar)
        UIView.animate(withDuration: 1) { window.layoutIfNeeded() }
        func frameAnimations(_ view: UIView) -> [String] {
            (view.layer.animationKeys() ?? []).filter { $0.hasPrefix("position") || $0.hasPrefix("bounds") }
                + view.subviews.flatMap(frameAnimations)
        }
        #expect(frameAnimations(bar.debugEmoteToggle).isEmpty, "the emote button grew from a zero frame")
        #expect(frameAnimations(bar.debugRowActionButton).isEmpty, "the bubble grew from a zero frame")
        #expect(bar.debugEmoteToggle.frame.minX > 0, "the emote button is still at the corner")
        // Later layouts animate as asked: the keyboard's rise rides its block.
        bar.setNeedsLayout()
        UIView.animate(withDuration: 1) { bar.frame.origin.y = 600; window.layoutIfNeeded() }
        #expect(!(bar.layer.animationKeys() ?? []).isEmpty, "a later layout no longer animates")
    }

    /// Typed fast: the button comes back while its slot is still closing.
    /// The closing stops where it stands, so no frame of the button runs on
    /// under its way in (the owner's video, 2026-11-09: the glyph came in
    /// stretched from the left).
    @Test func aButtonBackWhileItsSlotClosesCarriesNoFrameMotion() async {
        let (_, bar, _) = composer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        bar.frame = CGRect(x: 0, y: 700, width: 390, height: 120)
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        bar.layoutIfNeeded()
        let toggle = bar.debugEmoteToggle
        bar.draftText = "a"
        bar.draftText = ""
        // Out, and its slot on its way closed.
        #expect(await settle { toggle.isHidden }, "the emote button never left")
        bar.draftText = "b"
        func frameAnimations(_ view: UIView) -> [String] {
            (view.layer.animationKeys() ?? []).filter { $0.hasPrefix("position") || $0.hasPrefix("bounds") }
                + view.subviews.flatMap(frameAnimations)
        }
        #expect(frameAnimations(toggle).isEmpty, "the slot's closing ran on under the way in: \(frameAnimations(toggle))")
        #expect(bar.debugEmoteSlotWidth == CommentsInputBar.Metrics.emoteToggleWidth)
        #expect(toggle.bounds.width == CommentsInputBar.Metrics.emoteToggleWidth)
    }

    /// Typed fast: the next letters of the draft leave the emote button's
    /// way in running to its end, and its way out too (the owner,
    /// 2026-11-09: the bounce was cut at the second letter).
    @Test func theNextLettersLeaveTheEmoteButtonsMotionRunning() async {
        let (_, bar, _) = composer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        bar.frame = CGRect(x: 0, y: 700, width: 390, height: 120)
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        bar.layoutIfNeeded()
        let toggle = bar.debugEmoteToggle
        bar.draftText = "h"
        #expect(toggle.layer.animation(forKey: "transform") != nil, "no bounce on the way in")
        bar.draftText = "he"
        bar.draftText = "hey"
        #expect(toggle.layer.animation(forKey: "transform") != nil, "the next letters cut the bounce")
        #expect(toggle.transform == .identity, "the bounce does not end at full size")
        bar.draftText = ""
        let leaving = toggle.layer.animationKeys() ?? []
        bar.draftText = ""
        #expect(!leaving.isEmpty, "no motion on the way out")
        #expect(!(toggle.layer.animationKeys() ?? []).isEmpty, "the same empty field again cut the way out")
        #expect(bar.debugEmoteSlotWidth == CommentsInputBar.Metrics.emoteToggleWidth, "the slot closed under the way out")
        #expect(await settle { toggle.isHidden && bar.debugEmoteSlotWidth == 0 }, "the way out never ended")
    }

    /// A post's comments declare no voice (#2309 comes next): no hold.
    @Test func aPostsComposerHasNoHold() {
        let bar = CommentsInputBar()
        #expect(!bar.speaksFromField)
        #expect(!bar.debugFieldHoldBegins)
    }
}
