import AVFoundation
import UIKit

/// A finished take: its file, how long it is, and its waveform (#2101).
public struct VoiceDraft: Equatable, Sendable {
    public let fileURL: URL
    public let duration: TimeInterval
    /// `VoiceWaveform.levelCount` levels, 0…`VoiceWaveform.maxLevel`.
    public let waveform: [UInt8]

    public init(fileURL: URL, duration: TimeInterval, waveform: [UInt8]) {
        self.fileURL = fileURL
        self.duration = duration
        self.waveform = waveform
    }
}

/// What records a take — `AVAudioRecorder` in the app, a fake in tests.
@MainActor
public protocol VoiceRecordingDevice: AnyObject {
    /// Opens a recorder writing `VoiceRecorder.settings` to `url`, metering on.
    func prepare(writingTo url: URL) throws
    /// Starts, or resumes into the same file.
    func record() -> Bool
    func pause()
    func stop()
    /// Seconds recorded, pauses excluded.
    var currentTime: TimeInterval { get }
    /// The latest average and peak power, in dBFS.
    func meter() -> (average: Float, peak: Float)
}

@MainActor
public final class AudioRecorderDevice: VoiceRecordingDevice {
    private var recorder: AVAudioRecorder?

    public init() {}

    public func prepare(writingTo url: URL) throws {
        let recorder = try AVAudioRecorder(url: url, settings: VoiceRecorder.settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else { throw VoiceRecorder.Failure.couldNotPrepare }
        self.recorder = recorder
    }

    public func record() -> Bool { recorder?.record() ?? false }
    public func pause() { recorder?.pause() }
    public func stop() { recorder?.stop() }
    public var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

    public func meter() -> (average: Float, peak: Float) {
        guard let recorder else { return (-160, -160) }
        recorder.updateMeters()
        return (recorder.averagePower(forChannel: 0), recorder.peakPower(forChannel: 0))
    }
}

/// Records a voice message (#2101): `idle → recording ⇄ paused →
/// finished(draft) | cancelled`.
///
/// - **Pause and resume continue the same take**, into one file
///   (`AVAudioRecorder`'s own pause).
/// - **Under `minimumDuration` is too short:** the file goes and the caller
///   is told.
/// - **At `maximumDuration`** the take stops into a finished draft — never
///   sent on its own — after `onTimeRunningOut` `warningLead` before.
/// - **An interruption never loses a take and never sends one:** a call,
///   Siri or an alarm, the app leaving the screen, the microphone going away
///   — each finishes it into a draft (`onAutoFinish`), the 1 s rule applying.
/// - **The session is the recording role** while it records, given back with
///   `notifyOthersOnDeactivation` after; whatever was playing is paused first
///   (`VoiceAudioFocus`). The screen stays awake meanwhile.
@MainActor
public final class VoiceRecorder {
    public enum State: Equatable, Sendable {
        case idle, recording, paused, finished(VoiceDraft), cancelled
    }

    public enum StartOutcome: Equatable, Sendable {
        case started
        /// The permission was just asked. Nothing recorded behind the alert:
        /// granted, the next hold records.
        case askedPermission(granted: Bool)
        /// Refused before: the caller offers Settings.
        case denied
        case failed
    }

    public enum FinishOutcome: Equatable, Sendable {
        case draft(VoiceDraft)
        case tooShort
    }

    enum Failure: Error { case couldNotPrepare, couldNotRecord }

    /// AAC-LC in `.m4a`, mono, 24 kHz, 32 kbps — Signal's choice: the native
    /// recorder writes it, and it plays everywhere.
    public static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 24_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    public static let minimumDuration: TimeInterval = 1
    public static let maximumDuration: TimeInterval = 15 * 60
    /// How long before the limit `onTimeRunningOut` is told.
    public static let warningLead: TimeInterval = 10
    /// The metering's rate: 20 Hz.
    public static let meterInterval: TimeInterval = 0.05

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    /// The live level, 0…1, for the composer's waveform and its breathing mic.
    public private(set) var level: Float = 0
    /// Seconds recorded so far.
    public var elapsed: TimeInterval { device?.currentTime ?? 0 }

    public var onStateChange: ((State) -> Void)?
    public var onLevel: ((Float) -> Void)?
    /// `warningLead` left before the limit, once per take.
    public var onTimeRunningOut: (() -> Void)?
    /// A take the recorder finished on its own: the limit or an interruption.
    public var onAutoFinish: ((FinishOutcome) -> Void)?

    private let session: any VoiceAudioSessionControlling
    private let permission: any VoiceMicrophonePermission
    private let makeDevice: () -> any VoiceRecordingDevice
    private let ticker: any VoiceTicking
    private let notifications: NotificationCenter
    private let directory: URL
    private let keepAwake: (Bool) -> Void

    private var device: (any VoiceRecordingDevice)?
    private var fileURL: URL?
    private var samples: [Float] = []
    private var warned = false
    private var observers: [NSObjectProtocol] = []

    public init(
        session: any VoiceAudioSessionControlling = AVAudioSession.sharedInstance(),
        permission: any VoiceMicrophonePermission = SystemMicrophonePermission(),
        makeDevice: @escaping () -> any VoiceRecordingDevice = { AudioRecorderDevice() },
        ticker: any VoiceTicking = TimerTicker(),
        notifications: NotificationCenter = .default,
        directory: URL = FileManager.default.temporaryDirectory.appending(path: "voice-takes", directoryHint: .isDirectory),
        keepAwake: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }
    ) {
        self.session = session
        self.permission = permission
        self.makeDevice = makeDevice
        self.ticker = ticker
        self.notifications = notifications
        self.directory = directory
        self.keepAwake = keepAwake
    }

    var isTaking: Bool { state == .recording || state == .paused }

    // MARK: - Recording

    /// Starts a take — or, the first time, asks for the microphone and
    /// records nothing.
    public func start() async -> StartOutcome {
        guard !isTaking else { return .failed }
        switch permission.state {
        case .denied:
            return .denied
        case .undetermined:
            let granted = await permission.request()
            return .askedPermission(granted: granted)
        case .granted:
            break
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "\(UUID().uuidString).m4a")
            notifications.post(name: VoiceAudioFocus.didTake, object: self)
            try VoiceSessionRole.recording.apply(to: session)
            let device = makeDevice()
            try device.prepare(writingTo: url)
            guard device.record() else { throw Failure.couldNotRecord }
            self.device = device
            fileURL = url
        } catch {
            teardown()
            return .failed
        }
        samples = []
        warned = false
        keepAwake(true)
        observeInterruptions()
        ticker.start(interval: Self.meterInterval) { [weak self] in self?.tick() }
        state = .recording
        return .started
    }

    public func pause() {
        guard state == .recording, let device else { return }
        device.pause()
        setLevel(0)
        state = .paused
    }

    public func resume() {
        guard state == .paused, let device, device.record() else { return }
        state = .recording
    }

    /// Ends the take: a draft, or too short (its file deleted).
    @discardableResult
    public func finish() -> FinishOutcome? {
        guard isTaking, let device, let fileURL else { return nil }
        let duration = device.currentTime
        device.stop()
        teardown()
        guard duration >= Self.minimumDuration else {
            try? FileManager.default.removeItem(at: fileURL)
            state = .cancelled
            return .tooShort
        }
        let draft = VoiceDraft(fileURL: fileURL, duration: duration, waveform: VoiceWaveform.levels(from: samples))
        state = .finished(draft)
        return .draft(draft)
    }

    /// Drops the take and its file.
    public func cancel() {
        guard isTaking else { return }
        device?.stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        teardown()
        state = .cancelled
    }

    /// Back to idle for the next take, once finished or cancelled.
    public func reset() {
        guard !isTaking else { return }
        state = .idle
    }

    // MARK: - Metering and the limit

    /// Every `meterInterval`: the level, a sample for the waveform, the
    /// limit.
    func tick() {
        guard let device else { return }
        if state == .recording {
            let meter = device.meter()
            samples.append(VoiceWaveform.amplitude(decibels: meter.peak))
            setLevel(VoiceWaveform.amplitude(decibels: meter.average))
        }
        let elapsed = device.currentTime
        if !warned, elapsed >= Self.maximumDuration - Self.warningLead {
            warned = true
            onTimeRunningOut?()
        }
        if elapsed >= Self.maximumDuration { autoFinish() }
    }

    private func setLevel(_ level: Float) {
        self.level = level
        onLevel?(level)
    }

    private func autoFinish() {
        guard let outcome = finish() else { return }
        onAutoFinish?(outcome)
    }

    // MARK: - Interruptions

    private func observeInterruptions() {
        let center = notifications
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
                [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init) == .began
                MainActor.assumeIsolated { if began { self?.autoFinish() } }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.autoFinish() }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
                [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init)
                MainActor.assumeIsolated {
                    guard let self, reason == .oldDeviceUnavailable, !self.session.isInputAvailable else { return }
                    self.autoFinish()
                }
            },
        ]
    }

    private func teardown() {
        ticker.stop()
        for observer in observers { notifications.removeObserver(observer) }
        observers = []
        device = nil
        setLevel(0)
        keepAwake(false)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        notifications.post(name: VoiceAudioFocus.didRelease, object: self)
    }
}
