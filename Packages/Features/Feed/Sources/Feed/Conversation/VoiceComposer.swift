import DesignSystem
import FeedInterface
import UIKit
import VoiceKit

/// Recording a voice message from a conversation's composer (#2102): hold
/// the empty field to talk (#2183), slide to cancel, slide up to lock, then
/// pause, listen back, resume, delete or send.
///
/// The bar reports the finger (`CommentsInputBar.VoiceHoldEvent`), the
/// thresholds are `VoiceHoldGesture`'s, the take is #2101's `VoiceRecorder`,
/// and the sends are the thread's (`onSend`, #2103). This draws in the
/// field's place (`VoiceRecordingStrip`), on the row's own action bubble
/// (it grows into the mic while the field is held,
/// `CommentsInputBar.beginVoiceHold`) and over the content (the lock).
@MainActor
final class VoiceComposer {
    enum Phase: Equatable {
        case idle
        /// The finger is down; the UI shows `revealDelay` after touch-down.
        case holding(revealed: Bool)
        case locked
        /// Paused: `resumable` while the take is still open — after a listen
        /// back or an interruption it is a finished draft.
        case paused(resumable: Bool)
    }

    private(set) var phase: Phase = .idle {
        didSet { onPhaseChange?(phase) }
    }

    var onSend: ((ConversationThreadVoiceTake) -> Void)?
    /// Refused before: the screen offers Settings.
    var onPermissionDenied: (() -> Void)?
    /// "Hold to record, release to send": a tap, or a take under 1 s.
    var onHint: ((String) -> Void)?
    var onPhaseChange: ((Phase) -> Void)?

    static let hint = "Hold to record, release to send"

    /// Locked or paused takes left behind, per conversation, for the app's
    /// session (#2102): coming back shows the paused bar.
    private static var drafts: [String: VoiceDraft] = [:]

    let recorder: VoiceRecorder
    private let draftKey: String?
    private let now: () -> Date
    private weak var bar: CommentsInputBar?
    private weak var host: UIView?
    private let strip = VoiceRecordingStrip()
    private let lock = VoiceLockCapsule()
    private var holdStarted: Date?
    private var fingerDown = false
    private var draft: VoiceDraft?
    private var clock: Timer?

    init(recorder: VoiceRecorder = VoiceRecorder(), draftKey: String?, now: @escaping () -> Date = Date.init) {
        self.recorder = recorder
        self.draftKey = draftKey
        self.now = now
        recorder.onLevel = { [weak self] level in self?.levelChanged(level) }
        recorder.onAutoFinish = { [weak self] outcome in self?.autoFinished(outcome) }
        recorder.onTimeRunningOut = { [weak self] in self?.tickClock() }
        strip.onPause = { [weak self] in self?.pause() }
        strip.onResume = { [weak self] in self?.resume() }
        strip.onPlay = { [weak self] in self?.listenBack() }
        strip.onSend = { [weak self] in self?.send() }
        strip.onSeek = { [weak self] fraction in self?.seekListenBack(to: fraction) }
    }

    /// The bar it records from and the view the mic and the lock float in.
    func attach(to bar: CommentsInputBar, host: UIView) {
        self.bar = bar
        self.host = host
        bar.holdsToRecord = true
        bar.onVoiceHold = { [weak self] event in self?.handle(event) }
        if let key = draftKey, let kept = Self.drafts.removeValue(forKey: key) {
            draft = kept
            showPaused(resumable: false)
        }
    }

    // MARK: - The finger

    func handle(_ event: CommentsInputBar.VoiceHoldEvent) {
        switch event {
        case .began:
            guard phase == .idle else { return }
            fingerDown = true
            holdStarted = now()
            phase = .holding(revealed: false)
            Task { await self.start(locked: false) }
        case .accessibilityStart:
            guard phase == .idle else { return }
            Task { await self.start(locked: true) }
        case .moved(let leading, let up):
            guard case .holding(true) = phase else { return }
            switch VoiceHoldGesture.outcome(leading: leading, up: up) {
            case .cancelled: cancel()
            case .locked: lockTake()
            case .holding(let cancel, let lockProgress):
                strip.setCancelProgress(cancel)
                lock.setProgress(lockProgress)
                bar?.moveVoiceHold(cancel: cancel, travel: VoiceHoldGesture.cancelTravel)
            }
        case .ended(let leading):
            fingerDown = false
            guard case .holding = phase else { return }
            switch VoiceHoldGesture.release(heldFor: now().timeIntervalSince(holdStarted ?? now()), leading: leading) {
            case .tap:
                recorder.cancel()
                recorder.reset()
                reset()
                onHint?(Self.hint)
            case .cancel:
                cancel()
            case .send:
                send()
            }
        case .cancelled:
            fingerDown = false
            if case .holding = phase { cancel() }
        }
    }

    private func start(locked: Bool) async {
        if case .finished = recorder.state { recorder.reset() }
        if recorder.state == .cancelled { recorder.reset() }
        switch await recorder.start() {
        case .started:
            Haptics.play(.commit)
            if locked {
                lockTake()
                UIAccessibility.post(notification: .announcement, argument: "Recording")
                return
            }
            // A finger lifted while the microphone was opening: a tap, so
            // nothing is kept.
            guard fingerDown, phase == .holding(revealed: false) else {
                recorder.cancel()
                recorder.reset()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + VoiceHoldGesture.revealDelay) { [weak self] in
                guard let self, self.phase == .holding(revealed: false) else { return }
                self.reveal()
            }
        case .askedPermission:
            // Nothing records behind the alert: the gesture ends there.
            reset()
        case .denied:
            reset()
            onPermissionDenied?()
        case .failed:
            reset()
        }
    }

    // MARK: - The phases

    private func reveal() {
        phase = .holding(revealed: true)
        strip.apply(.recording)
        strip.setCancelProgress(0)
        // The time is there before the strip shows, so it is laid out with
        // it — set by the clock's first tick, it came in from nothing
        // inside the bubble's spring.
        strip.setTime(recorder.elapsed, remaining: nil)
        bar?.showVoiceOverlay(strip)
        // The bubble itself grows into the mic (the owner, 2026-11-07).
        bar?.beginVoiceHold()
        startClock()
        guard let bar, let host else { return }
        let anchor = bar.voiceHoldAnchor.convert(
            CGPoint(x: bar.voiceHoldAnchor.bounds.midX, y: bar.voiceHoldAnchor.bounds.midY), to: host
        )
        // A lock still leaving (the last take's) comes back from where it is.
        lockGeneration += 1
        lock.layer.removeAllAnimations()
        lock.transform = .identity
        lock.setProgress(0)
        lock.center = CGPoint(
            x: anchor.x, y: anchor.y - CommentsInputBar.voiceHoldSide / 2 - VoiceLockCapsule.size.height / 2 - 16
        )
        host.addSubview(lock)
        lock.alpha = 1
        if window(host) && !MotionPreference.reducesMotion {
            // It rises out of the bubble, small, and settles in its place.
            lock.alpha = 0
            lock.transform = CGAffineTransform(translationX: 0, y: 24).scaledBy(x: 0.6, y: 0.6)
            UIView.animate(springDuration: 0.45, bounce: 0.3, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.lock.alpha = 1
                self.lock.transform = .identity
            }
        }
    }

    /// Counts the lock's comings and goings, so a removal left over from a
    /// take never takes away the next one's lock.
    private var lockGeneration = 0

    /// The lock goes — locked (it rises, closed), sent, cancelled — fading,
    /// unless `animated` is false (leaving the conversation).
    private func dismissLock(animated: Bool = true) {
        lockGeneration += 1
        guard lock.superview != nil else { return }
        let generation = lockGeneration
        let finish = { [weak self] in
            guard let self, generation == lockGeneration else { return }
            lock.removeFromSuperview()
            lock.alpha = 1
            lock.transform = .identity
        }
        guard animated, lock.window != nil, !MotionPreference.reducesMotion else {
            lock.layer.removeAllAnimations()
            return finish()
        }
        UIView.animate(withDuration: 0.28, delay: 0, options: [.beginFromCurrentState]) {
            self.lock.alpha = 0
            self.lock.transform = CGAffineTransform(translationX: 0, y: -18).scaledBy(x: 0.85, y: 0.85)
        } completion: { _ in
            finish()
        }
    }

    private func window(_ view: UIView) -> Bool { view.window != nil }

    private func lockTake() {
        // A commit, felt: the take is the finger's no longer (the owner,
        // 2026-11-07 — the boundary's light tap went unfelt).
        Haptics.play(.commit)
        lock.close()
        phase = .locked
        dismissLock()
        strip.apply(.locked, animated: true)
        // The bubble steps aside first, so it leaves wearing the mic.
        bar?.showVoiceOverlay(strip, coversButton: true)
        bar?.endVoiceHold()
        showBin()
        startClock()
    }

    private func pause() {
        guard phase == .locked else { return }
        recorder.pause()
        showPaused(resumable: true)
    }

    private func resume() {
        guard phase == .paused(resumable: true) else { return }
        VoicePlayer.shared.stop()
        recorder.resume()
        phase = .locked
        strip.apply(.locked, animated: true)
        startClock()
    }

    private func showPaused(resumable: Bool) {
        phase = .paused(resumable: resumable)
        stopClock()
        strip.apply(.paused(resumable: resumable, playing: false), animated: true)
        bar?.showVoiceOverlay(strip, coversButton: true)
        showBin()
        strip.layoutIfNeeded()
        if let draft {
            strip.showTake(levels: draft.waveform, duration: draft.duration, progress: 0)
        } else {
            strip.setTime(recorder.elapsed, remaining: nil)
        }
    }

    /// ▶︎ on the paused bar. A take still open is finished first — an `.m4a`
    /// plays only once closed — so it can no longer be resumed.
    private func listenBack() {
        if draft == nil {
            guard case .draft(let finished) = recorder.finish() else { return reset() }
            draft = finished
        }
        guard let draft else { return }
        let player = VoicePlayer.shared
        let id = "voice-draft-\(draft.fileURL.lastPathComponent)"
        player.onChange = { [weak self] in self?.listenBackChanged(id: id) }
        player.toggle(id, url: draft.fileURL)
        listenBackChanged(id: id)
    }

    private func listenBackChanged(id: String) {
        guard let draft, case .paused = phase else { return }
        let player = VoicePlayer.shared
        let playing = player.messageID == id && player.state == .playing
        phase = .paused(resumable: false)
        strip.apply(.paused(resumable: false, playing: playing))
        strip.showTake(levels: draft.waveform, duration: draft.duration, progress: player.progress ?? 0)
    }

    private func seekListenBack(to fraction: Double) {
        guard draft != nil else { return }
        VoicePlayer.shared.seek(to: fraction)
    }

    /// Release, or ↑: the take as it is.
    private func send() {
        stopClock()
        VoicePlayer.shared.stop()
        let outcome: VoiceRecorder.FinishOutcome? = if let draft { .draft(draft) } else { recorder.finish() }
        switch outcome {
        case .draft(let take):
            onSend?(ConversationThreadVoiceTake(fileURL: take.fileURL, duration: take.duration, waveform: take.waveform))
        case .tooShort:
            Haptics.play(.warning)
            onHint?(Self.hint)
        case nil:
            break
        }
        recorder.reset()
        reset()
    }

    /// Slid away, released past 55 %, or 🗑: the take goes, with the bin.
    private func cancel() {
        stopClock()
        VoicePlayer.shared.stop()
        recorder.cancel()
        recorder.reset()
        if let draft { try? FileManager.default.removeItem(at: draft.fileURL) }
        Haptics.play(.warning)
        // Slid away: the bubble goes straight back to its place and face.
        reset()
    }

    /// An interruption or the limit: the take stops into the paused bar —
    /// nothing lost, nothing sent.
    private func autoFinished(_ outcome: VoiceRecorder.FinishOutcome) {
        switch outcome {
        case .draft(let finished):
            draft = finished
            dismissLock()
            showPaused(resumable: false)
            bar?.endVoiceHold()
        case .tooShort:
            reset()
        }
    }

    private func reset() {
        stopClock()
        draft = nil
        bar?.endVoiceHold()
        dismissLock()
        bar?.showVoiceOverlay(nil)
        bar?.showVoiceDelete(nil)
        phase = .idle
    }

    /// The bin in the avatar's place: the locked and paused bars' delete.
    private func showBin() {
        bar?.showVoiceDelete { [weak self] in self?.cancel() }
    }

    /// Leaving the conversation: a locked or paused take is kept as its
    /// draft for the app's session; one still under the finger goes.
    func leave() {
        switch phase {
        case .locked, .paused:
            if draft == nil, case .draft(let finished) = recorder.finish() { draft = finished }
            if let key = draftKey, let draft { Self.drafts[key] = draft }
            VoicePlayer.shared.stop()
            stopClock()
            bar?.endVoiceHold()
            dismissLock(animated: false)
            phase = .idle
            draft = nil
        case .holding:
            cancel()
        case .idle:
            break
        }
    }

    // MARK: - The clock and the level

    private func startClock() {
        stopClock()
        tickClock()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    private func tickClock() {
        let elapsed = recorder.elapsed
        strip.setTime(elapsed, remaining: VoiceRecorder.maximumDuration - elapsed)
    }

    private func levelChanged(_ level: Float) {
        if case .holding = phase { bar?.setVoiceHoldLevel(level) }
        if phase == .locked { strip.appendLevel(level) }
    }

    #if DEBUG
    var debugStrip: VoiceRecordingStrip { strip }
    var debugShowsDisc: Bool { bar?.isVoiceHolding == true }
    static func debugDraft(for key: String) -> VoiceDraft? { drafts[key] }
    static func debugClearDrafts() { drafts = [:] }
    #endif
}

#if DEBUG
extension VoiceComposer {
    /// The lock over the mic, for the specs that watch it come and go.
    var debugLock: UIView { lock }
}
#endif
