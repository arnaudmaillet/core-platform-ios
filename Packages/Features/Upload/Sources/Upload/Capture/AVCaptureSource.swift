@preconcurrency import AVFoundation
import Synchronization
import UIKit

/// The device's cameras, through AVFoundation.
///
/// ⚠️ **VERIFIABLE ON A PHONE ONLY.** A simulator exposes no capture device at
/// all (see `CaptureSource`), so every line below compiles in CI and runs
/// nowhere but on hardware; `SimulatedCaptureSource` is what the suite and the
/// simulator drive. What is written here follows Apple's documented contracts
/// and says so where it leans on one.
///
/// ⚠️ **THE SESSION IS CONFIGURED AND STARTED OFF THE MAIN THREAD**, on one
/// serial queue: `startRunning()` and `commitConfiguration()` are documented as
/// blocking, and on the main thread they land as a hitch in the sheet's
/// presentation — the note the deleted `CameraViewController` carried.
///
/// ⚠️ **THE PREVIEW HAS TWO PATHS AND ONLY PAYS FOR THE ONE IT SHOWS.** With no
/// look chosen, `AVCaptureVideoPreviewLayer` draws the camera in the render
/// server, at no cost to this process; the video data output's connection is
/// switched OFF (`feed.wantsFrames`). Only a look — or the filter row, whose
/// cards show the live frame — turns it on, and then every frame goes through
/// `CaptureLiveView`'s Core Image → Metal path.
///
/// ⚠️ **THE VIRTUAL MULTI-CAMERA IS PREFERRED**, so zoom crosses from the
/// ultra-wide to the wide to the telephoto as one continuous factor and the
/// device switches lenses itself at `virtualDeviceSwitchOverVideoZoomFactors`
/// — the lens chips are those switch-over points, in display terms.
@MainActor
final class AVCaptureSource: CaptureSource {
    let feed = CaptureFrameFeed()
    private let engine: AVCaptureEngine
    private let previewView = CapturePreviewLayerView()

    /// Whether any camera exists — see `makeCaptureSource()`.
    static var hasAnyCamera: Bool {
        !AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
        ).devices.isEmpty
    }

    init() {
        engine = AVCaptureEngine(feed: feed)
        previewView.previewLayer.session = engine.session
        previewView.previewLayer.videoGravity = .resizeAspectFill
    }

    func authorize() async -> CaptureAuthorization {
        var video = AVCaptureDevice.authorizationStatus(for: .video)
        if video == .notDetermined {
            video = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        }
        guard video == .authorized else { return .denied }
        var audio = AVCaptureDevice.authorizationStatus(for: .audio)
        if audio == .notDetermined {
            audio = await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
        }
        // ⚠️ A REFUSED MICROPHONE IS NOT A REFUSED CAMERA. Clips are then
        // silent, which is still a video the author can post.
        engine.includesAudio = audio == .authorized
        return .authorized(microphone: audio == .authorized)
    }

    func start() {
        engine.start { [weak self] snapshot in
            Task { @MainActor in self?.adopt(snapshot) }
        }
    }

    func stop() { engine.stop() }

    var plainPreview: UIView? { previewView }

    private(set) var position: CapturePosition = .back
    private(set) var lenses: [CaptureLens] = [CaptureLens(factor: 1)]
    private(set) var zoomRange: ClosedRange<CGFloat> = 1...1
    private(set) var zoom: CGFloat = 1
    private(set) var hasFlash = false
    /// Device zoom factor for display factor 1 — 2 on a phone with an
    /// ultra-wide, where the virtual device's factor 1 IS the ultra-wide.
    private var displayScale: CGFloat = 1

    var onStateChange: (() -> Void)?

    private func adopt(_ snapshot: AVCaptureEngine.Snapshot) {
        defer { onStateChange?() }
        position = snapshot.position
        displayScale = snapshot.displayScale
        lenses = snapshot.lensFactors.map(CaptureLens.init(factor:))
        zoomRange = snapshot.zoomRange
        zoom = snapshot.zoom
        hasFlash = snapshot.hasFlash
        if let angle = snapshot.previewRotation,
           previewView.previewLayer.connection?.isVideoRotationAngleSupported(angle) == true {
            previewView.previewLayer.connection?.videoRotationAngle = angle
        }
    }

    func flip() async {
        let snapshot = await engine.switchTo(position.flipped)
        adopt(snapshot)
    }

    func setZoom(_ factor: CGFloat, smoothly: Bool) {
        zoom = min(max(factor, zoomRange.lowerBound), zoomRange.upperBound)
        engine.setZoom(zoom * displayScale, smoothly: smoothly)
    }

    func focus(at point: CGPoint) {
        let layerPoint = CGPoint(x: point.x * previewView.bounds.width, y: point.y * previewView.bounds.height)
        let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        engine.focus(at: devicePoint)
    }

    func capturePhoto(flash: CaptureFlashMode, into folder: CaptureFolder) async throws -> CapturedPhoto {
        let url = folder.newFile("capture", pathExtension: "jpg")
        return try await engine.photograph(to: url, flash: flash)
    }

    func startRecording(to url: URL, torch: Bool, limit: TimeInterval) -> CaptureClipPromise {
        engine.record(to: url, torch: torch, limit: limit)
    }

    func stopRecording() { engine.stopRecording() }

    var recordedDuration: TimeInterval { engine.recordedDuration }

    func setDeliversFrames(_ on: Bool) {
        feed.wantsFrames = on
        engine.refreshFrameDelivery()
    }
}

/// A view whose layer IS the preview layer, so it lays itself out.
@MainActor
final class CapturePreviewLayerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }
}

/// The session and everything that touches it, on its own serial queue.
///
/// ⚠️ **NONISOLATED, FOR THE TRAP `SimulatedCaptureEngine` STATES.** Every
/// closure handed to AVFoundation — the sample-buffer delegate, the photo and
/// recording delegates, the queue blocks — is formed in here. A delegate
/// written as a `@MainActor` type compiles and traps on the first callback.
final class AVCaptureEngine: NSObject, @unchecked Sendable {
    struct Snapshot: Sendable {
        var position: CapturePosition
        var displayScale: CGFloat
        var lensFactors: [CGFloat]
        var zoomRange: ClosedRange<CGFloat>
        var zoom: CGFloat
        var hasFlash: Bool
        var previewRotation: CGFloat?
    }

    let session = AVCaptureSession()
    private let feed: CaptureFrameFeed
    private let queue = DispatchQueue(label: "capture.session")
    private let frameQueue = DispatchQueue(label: "capture.frames", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let dataOutput = AVCaptureVideoDataOutput()
    /// Touched on `queue` only.
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var photoDelegates: [Int64: PhotoDelegate] = [:]
    private var recordingDelegate: RecordingDelegate?
    private var currentPosition: CapturePosition = .back
    private let wantsAudio = Mutex(false)

    var includesAudio: Bool {
        get { wantsAudio.withLock { $0 } }
        set { wantsAudio.withLock { $0 = newValue } }
    }

    init(feed: CaptureFrameFeed) {
        self.feed = feed
        super.init()
    }

    func start(_ report: @escaping @Sendable (Snapshot) -> Void) {
        queue.async { [self] in
            if !isConfigured {
                isConfigured = true
                configure()
            }
            if !session.isRunning { session.startRunning() }
            report(snapshot())
        }
    }

    func stop() {
        queue.async { [self] in
            if movieOutput.isRecording { movieOutput.stopRecording() }
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // 1080p, 16:9 — video and photographs share the frame the preview shows,
        // so the ratio's crop is the same rectangle on both.
        session.sessionPreset = .high
        installCamera(.back)
        if includesAudio, let microphone = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .balanced
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        dataOutput.setSampleBufferDelegate(self, queue: frameQueue)
        // ⚠️ iOS 16 LIFTED THE OLD RULE that a movie file output and a video
        // data output could not share a session; this target is iOS 26.
        if session.canAddOutput(dataOutput) { session.addOutput(dataOutput) }
        applyConnections()
    }

    private static func device(for position: CapturePosition) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: position == .back ? .back : .front
        )
        // The discovery lists in the order of `deviceTypes`, most capable first.
        return discovery.devices.first
    }

    private func installCamera(_ position: CapturePosition) {
        guard let device = Self.device(for: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        if let videoInput { session.removeInput(videoInput) }
        guard session.canAddInput(input) else {
            if let videoInput { session.addInput(videoInput) }
            return
        }
        session.addInput(input)
        videoInput = input
        currentPosition = position
        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = dimensions
        }
        // Start on the wide lens, which is display factor 1.
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = Self.displayScale(of: device)
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }
    }

    /// ⚠️ THE ROTATION IS THE COORDINATOR'S, READ AT EACH CAPTURE — so a photo
    /// taken with the phone turned is level, and the preview follows the
    /// interface. Mirroring follows what the author SAW: a front-camera capture
    /// keeps the reflection the preview showed, the social cameras' convention.
    private func applyConnections() {
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        let mirrored = currentPosition == .front
        for output in [photoOutput, movieOutput, dataOutput] as [AVCaptureOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
        dataOutput.connection(with: .video)?.isEnabled = feed.wantsFrames
    }

    /// Display factor 1 in device terms: the first switch-over when the virtual
    /// device starts on an ultra-wide.
    private static func displayScale(of device: AVCaptureDevice) -> CGFloat {
        let startsWide = device.constituentDevices.first?.deviceType == .builtInUltraWideCamera
        guard startsWide, let first = device.virtualDeviceSwitchOverVideoZoomFactors.first else { return 1 }
        return CGFloat(truncating: first)
    }

    private func snapshot() -> Snapshot {
        guard let device = videoInput?.device else {
            return Snapshot(
                position: currentPosition, displayScale: 1, lensFactors: [1],
                zoomRange: 1...1, zoom: 1, hasFlash: false, previewRotation: nil
            )
        }
        let scale = Self.displayScale(of: device)
        let low = device.minAvailableVideoZoomFactor / scale
        // A cap well short of the digital maximum, where the picture is mush.
        let high = max(low, min(device.maxAvailableVideoZoomFactor, scale * 15) / scale)
        var factors = [low] + device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) / scale }
        // The 2× the system Camera offers from the main sensor's centre.
        if !factors.contains(where: { abs($0 - 2) < 0.2 }), high >= 2, factors.contains(where: { abs($0 - 1) < 0.01 }) {
            factors.append(2)
        }
        factors = Array(Set(factors.map { ($0 * 10).rounded() / 10 })).sorted()
        return Snapshot(
            position: currentPosition, displayScale: scale, lensFactors: factors,
            zoomRange: low...high, zoom: device.videoZoomFactor / scale,
            hasFlash: device.isFlashAvailable || device.hasTorch,
            previewRotation: rotation?.videoRotationAngleForHorizonLevelPreview
        )
    }

    func switchTo(_ position: CapturePosition) async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                session.beginConfiguration()
                installCamera(position)
                applyConnections()
                session.commitConfiguration()
                continuation.resume(returning: snapshot())
            }
        }
    }

    func setZoom(_ factor: CGFloat, smoothly: Bool) {
        queue.async { [self] in
            guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            if smoothly {
                device.ramp(toVideoZoomFactor: clamped, withRate: 8)
            } else {
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
        }
    }

    func focus(at devicePoint: CGPoint) {
        queue.async { [self] in
            guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        }
    }

    /// Switches the data output on or off to match `feed.wantsFrames`.
    func refreshFrameDelivery() {
        queue.async { [self] in
            dataOutput.connection(with: .video)?.isEnabled = feed.wantsFrames
        }
    }

    // MARK: - Photograph

    /// ⚠️ **NO SHUTTER SOUND OF OUR OWN.** `AVCapturePhotoOutput` plays the
    /// system's, which some regions require by law and which cannot be
    /// suppressed there; a second one would sound twice.
    func photograph(to url: URL, flash: CaptureFlashMode) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                applyConnections()
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                let wanted: AVCaptureDevice.FlashMode = switch flash {
                case .off: .off
                case .auto: .auto
                case .on: .on
                }
                if photoOutput.supportedFlashModes.contains(wanted) { settings.flashMode = wanted }
                let id = settings.uniqueID
                let delegate = PhotoDelegate(url: url) { [self] result in
                    queue.async { [self] in photoDelegates[id] = nil }
                    continuation.resume(with: result)
                }
                photoDelegates[id] = delegate
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    // MARK: - Recording

    var recordedDuration: TimeInterval {
        movieOutput.isRecording ? movieOutput.recordedDuration.seconds : 0
    }

    func record(to url: URL, torch: Bool, limit: TimeInterval) -> CaptureClipPromise {
        let promise = CaptureClipPromise()
        queue.async { [self] in
            guard !movieOutput.isRecording else {
                promise.fulfil(.failure(CaptureSourceError.recordingFailed))
                return
            }
            applyConnections()
            setTorch(torch)
            // ⚠️ THE TAKE'S BUDGET AS THE OUTPUT'S OWN HARD STOP: the
            // recording ends at exactly `limit`, reported as a successful
            // finish (`AVErrorMaximumDurationReached` with
            // `AVErrorRecordingSuccessfullyFinishedKey`).
            movieOutput.maxRecordedDuration = CMTime(seconds: limit, preferredTimescale: 600)
            let delegate = RecordingDelegate { [self] result in
                queue.async { [self] in
                    setTorch(false)
                    recordingDelegate = nil
                }
                promise.fulfil(result)
            }
            recordingDelegate = delegate
            movieOutput.startRecording(to: url, recordingDelegate: delegate)
        }
        return promise
    }

    func stopRecording() {
        queue.async { [self] in
            if movieOutput.isRecording { movieOutput.stopRecording() }
        }
    }

    private func setTorch(_ on: Bool) {
        guard let device = videoInput?.device, device.hasTorch,
              (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }
}

extension AVCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Mirroring is already in the pixels (`applyConnections`).
        feed.deliver(CaptureFrame(
            pixelBuffer: buffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), isMirrored: false
        ))
    }
}

/// One photograph's delegate: writes the file, reports once.
private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let url: URL
    private let done: @Sendable (Result<CapturedPhoto, any Error>) -> Void
    private var reported = false

    init(url: URL, done: @escaping @Sendable (Result<CapturedPhoto, any Error>) -> Void) {
        self.url = url
        self.done = done
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        guard !reported else { return }
        reported = true
        guard error == nil, let data = photo.fileDataRepresentation(),
              (try? data.write(to: url)) != nil else {
            done(.failure(error ?? CaptureSourceError.photoFailed))
            return
        }
        done(.success(CapturedPhoto(url: url, uprightSize: CapturedMediaLibrary.uprightImageSize(at: url) ?? .zero)))
    }
}

/// One clip's delegate.
private final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let done: @Sendable (Result<CaptureClip, any Error>) -> Void

    init(done: @escaping @Sendable (Result<CaptureClip, any Error>) -> Void) {
        self.done = done
    }

    func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection], error: (any Error)?
    ) {
        // ⚠️ AN ERROR CAN BE A SUCCESS: reaching `maxRecordedDuration` arrives
        // as an error whose user info says the file finished cleanly.
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
        guard error == nil || finished == true else {
            done(.failure(error ?? CaptureSourceError.recordingFailed))
            return
        }
        done(.success(CaptureClip(url: outputFileURL, duration: output.recordedDuration.seconds)))
    }
}
