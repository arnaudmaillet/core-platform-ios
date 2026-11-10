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
        /// back or an interruption it is a finished draft, and the 🎙 records
        /// on from its end as a second take, joined to it (`earlier`).
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
    /// Recording on after a listen back (the owner, 2026-11-08): the take
    /// before, closed, joined to the one recording now once it closes in
    /// turn (`closeTake`).
    private var earlier: VoiceDraft?
    /// Two closed takes as one: `VoiceTakeJoin` in the app, a fake in tests.
    private let join: (VoiceDraft, VoiceDraft) async throws -> VoiceDraft
    /// A join on its way: listening and sending wait for it.
    private(set) var isJoining = false
    private var clock: Timer?

    init(
        recorder: VoiceRecorder = VoiceRecorder(), draftKey: String?, now: @escaping () -> Date = Date.init,
        limit: TimeInterval = VoiceRecorder.maximumDuration,
        join: @escaping (VoiceDraft, VoiceDraft) async throws -> VoiceDraft = { first, second in
            try await VoiceTakeJoin.join(
                first, second,
                in: FileManager.default.temporaryDirectory.appending(path: "voice-takes", directoryHint: .isDirectory)
            )
        }
    ) {
        self.recorder = recorder
        recorder.limit = limit
        self.draftKey = draftKey
        self.now = now
        self.join = join
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

    /// The lock goes — locked (closed), sent, cancelled — sinking back into
    /// the bubble it rose from, fading, unless `animated` is false (leaving
    /// the conversation). The owner, 2026-11-08: it rose on its way out
    /// before, the opposite of how it came.
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
            self.lock.transform = CGAffineTransform(translationX: 0, y: 24).scaledBy(x: 0.6, y: 0.6)
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

    /// The 🎙 on the paused bar: the open take resumes, a closed one records
    /// on (`recordOn`).
    private func resume() {
        if phase == .paused(resumable: false) { return recordOn() }
        guard phase == .paused(resumable: true) else { return }
        VoicePlayer.shared.stop()
        recorder.resume()
        phase = .locked
        strip.apply(.locked, animated: true)
        startClock()
    }

    /// Records on from a closed take's end: a second take, joined to it when
    /// it closes in turn — listened back, sent, or left.
    private func recordOn() {
        guard let taken = draft, !isJoining else { return }
        VoicePlayer.shared.stop()
        Task {
            if case .finished = recorder.state { recorder.reset() }
            if recorder.state == .cancelled { recorder.reset() }
            guard case .started = await recorder.start(), phase == .paused(resumable: false), draft == taken else {
                return
            }
            earlier = taken
            draft = nil
            Haptics.play(.commit)
            phase = .locked
            strip.apply(.locked, animated: true)
            startClock()
        }
    }

    /// The take as one closed draft: the one kept, or the recorder's own —
    /// joined to the part before a record-on. A join that fails, or a second
    /// part under a second, leaves the part before.
    private func closeTake(_ done: @escaping (VoiceRecorder.FinishOutcome?) -> Void) {
        if let draft { return done(.draft(draft)) }
        let outcome = recorder.finish()
        guard let before = earlier else { return done(outcome) }
        earlier = nil
        guard case .draft(let after) = outcome else { return done(.draft(before)) }
        isJoining = true
        Task {
            let joined: VoiceDraft
            do {
                joined = try await join(before, after)
            } catch {
                try? FileManager.default.removeItem(at: after.fileURL)
                joined = before
            }
            isJoining = false
            done(.draft(joined))
        }
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
            strip.setTime(elapsed, remaining: nil)
        }
    }

    /// ▶︎ on the paused bar. A take still open is finished first — an `.m4a`
    /// plays only once closed — so it can no longer be resumed.
    private func listenBack() {
        guard !isJoining else { return }
        closeTake { [weak self] outcome in
            guard let self else { return }
            guard case .draft(let finished) = outcome else { return reset() }
            draft = finished
            let player = VoicePlayer.shared
            let id = "voice-draft-\(finished.fileURL.lastPathComponent)"
            player.onChange = { [weak self] in self?.listenBackChanged(id: id) }
            player.toggle(id, url: finished.fileURL)
            listenBackChanged(id: id)
        }
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
        guard !isJoining else { return }
        stopClock()
        VoicePlayer.shared.stop()
        closeTake { [weak self] outcome in
            guard let self else { return }
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
    }

    /// Slid away, released past 55 %, or 🗑: the take goes, with the bin.
    private func cancel() {
        discard()
        Haptics.play(.warning)
    }

    /// The take and its files go, with no feedback: the bar is idle again.
    private func discard() {
        stopClock()
        VoicePlayer.shared.stop()
        recorder.cancel()
        recorder.reset()
        for part in [draft, earlier].compactMap({ $0 }) { try? FileManager.default.removeItem(at: part.fileURL) }
        // Slid away: the bubble goes straight back to its place and face.
        reset()
    }

    // MARK: - A post's draft (#2209)

    /// Whether the bar holds a take a draft could keep: locked or paused.
    var hasTake: Bool {
        switch phase {
        case .locked, .paused: true
        case .idle, .holding: false
        }
    }

    /// The closed take on the bar, when it is one: a take put back by
    /// `restore(_:)` keeps its file until something is recorded on.
    var closedTakeURL: URL? { draft?.fileURL }

    /// The take on the bar, closed, for a post's draft to keep — and the bar
    /// idle again. Nil when there is no take, or one under a second. A take
    /// still under the finger goes, as it does on leaving.
    func takeForDraft(_ done: @escaping (VoiceDraft?) -> Void) {
        switch phase {
        case .locked, .paused:
            guard !isJoining else { return done(nil) }
            VoicePlayer.shared.stop()
            stopClock()
            closeTake { [weak self] outcome in
                // The file is the draft's now: nothing here removes it.
                self?.draft = nil
                self?.earlier = nil
                self?.recorder.reset()
                self?.reset()
                if case .draft(let kept) = outcome { done(kept) } else { done(nil) }
            }
        case .holding:
            discard()
            done(nil)
        case .idle:
            done(nil)
        }
    }

    /// A post's draft reopened with its voice: the take on the paused bar,
    /// as a conversation's kept take comes back (`attach`). Whatever was on
    /// the bar goes.
    func restore(_ take: VoiceDraft) {
        guard bar != nil else { return }
        if phase != .idle { discard() }
        draft = take
        showPaused(resumable: false)
    }

    /// The take goes without a word: another draft takes the composer.
    func clearTake() {
        guard phase != .idle else { return }
        discard()
    }

    /// An interruption or the limit: the take stops into the paused bar —
    /// nothing lost, nothing sent.
    private func autoFinished(_ outcome: VoiceRecorder.FinishOutcome) {
        switch outcome {
        case .draft:
            dismissLock()
            bar?.endVoiceHold()
            // Recording on: the part before and this one, as one.
            stopClock()
            closeTakeAfterAutoFinish(outcome)
        case .tooShort:
            if earlier != nil { closeTakeAfterAutoFinish(outcome) } else { reset() }
        }
    }

    /// The recorder already closed its take: joined to the part before, if
    /// any, into the paused bar.
    private func closeTakeAfterAutoFinish(_ outcome: VoiceRecorder.FinishOutcome) {
        let finish: (VoiceRecorder.FinishOutcome?) -> Void = { [weak self] closed in
            guard let self else { return }
            guard case .draft(let take) = closed else { return reset() }
            draft = take
            showPaused(resumable: false)
        }
        guard let before = earlier else { return finish(outcome) }
        earlier = nil
        guard case .draft(let after) = outcome else { return finish(.draft(before)) }
        isJoining = true
        Task {
            let joined = (try? await join(before, after)) ?? before
            isJoining = false
            finish(.draft(joined))
        }
    }

    private func reset() {
        stopClock()
        draft = nil
        earlier = nil
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
            let key = draftKey
            VoicePlayer.shared.stop()
            stopClock()
            bar?.endVoiceHold()
            dismissLock(animated: false)
            phase = .idle
            closeTake { outcome in
                if let key, case .draft(let kept) = outcome { Self.drafts[key] = kept }
            }
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

    /// The take's length: the part before a record-on, and this one.
    private var elapsed: TimeInterval { (earlier?.duration ?? 0) + recorder.elapsed }

    private func tickClock() {
        let total = elapsed
        let remaining = recorder.limit - total
        strip.setTime(total, remaining: remaining)
        // Recording on counts from the whole take: the limit is the take's,
        // where the recorder only knows its own part.
        if earlier != nil, remaining <= 0, phase == .locked {
            stopClock()
            recorder.pause()
            showPaused(resumable: true)
            listenBackOrClose()
        }
    }

    /// At the limit while recording on: the take closes into the paused bar.
    private func listenBackOrClose() {
        closeTake { [weak self] outcome in
            guard let self else { return }
            guard case .draft(let take) = outcome else { return reset() }
            draft = take
            showPaused(resumable: false)
        }
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
