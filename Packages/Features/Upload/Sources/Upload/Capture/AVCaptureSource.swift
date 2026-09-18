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

    /// The coordinator the PREVIEW is turned by — built here, on the main
    /// actor, with the preview layer itself.
    ///
    /// ⚠️ **A COORDINATOR WITHOUT A LAYER ANSWERS 0° FOR THE PREVIEW, BY
    /// CONTRACT.** The iOS 27 header on `initWithDevice:previewLayer:`: "If nil,
    /// the coordinator will return 0 degrees of rotation for horizon-level
    /// preview." The first version built only the engine's layer-less one and
    /// applied its preview angle — so on every phone the plain preview was
    /// set to 0°, the sensor's landscape, inside a portrait window: sideways.
    /// The engine keeps its own coordinator for the CAPTURE angle, which needs
    /// no layer.
    ///
    /// ⚠️ **OBSERVED, NOT READ ONCE.** The angle changes with the interface
    /// (this target allows landscape) and is 0 while the layer is outside a
    /// view hierarchy; the header says it is key-value observable "and
    /// delivers updates on the main queue". A flip replaces the coordinator,
    /// because it is keyed on the device.
    private var previewRotation: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?

    private func adopt(_ snapshot: AVCaptureEngine.Snapshot) {
        defer { onStateChange?() }
        position = snapshot.position
        displayScale = snapshot.displayScale
        lenses = snapshot.lensFactors.map(CaptureLens.init(factor:))
        zoomRange = snapshot.zoomRange
        zoom = snapshot.zoom
        hasFlash = snapshot.hasFlash
        followPreviewRotation(of: snapshot.deviceID)
    }

    private func followPreviewRotation(of deviceID: String?) {
        guard let deviceID, previewRotation?.device?.uniqueID != deviceID,
              let device = AVCaptureDevice(uniqueID: deviceID) else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewView.previewLayer)
        previewRotation = coordinator
        previewRotationObservation = Self.observePreviewAngle(of: coordinator) { [weak self] angle in
            self?.applyPreviewAngle(angle)
        }
    }

    /// ⚠️ **THE KVO HANDLER IS FORMED HERE, IN A NONISOLATED FUNCTION, AND HOPS
    /// TO THE MAIN ACTOR ITSELF.** Updates are documented to arrive on the main
    /// queue, but a closure formed inside this `@MainActor` type would carry a
    /// runtime isolation check, and the day one arrived elsewhere it would trap
    /// (`dispatch_assert_queue_fail`, the PhotoKit incident twice over).
    private nonisolated static func observePreviewAngle(
        of coordinator: AVCaptureDevice.RotationCoordinator,
        apply: @escaping @MainActor @Sendable (CGFloat) -> Void
    ) -> NSKeyValueObservation {
        coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in apply(angle) }
        }
    }

    /// The preview's angle, on both of the preview's paths: the plain layer,
    /// and the video data output the drawn preview and the filter cards read.
    private func applyPreviewAngle(_ angle: CGFloat) {
        engine.setPreviewAngle(angle)
        guard let connection = previewView.previewLayer.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
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
        /// The camera in use, by identifier — a `String` crosses to the main
        /// actor where a device may not, and is all the preview's rotation
        /// coordinator needs to find it again.
        var deviceID: String?
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
    /// The angle the PREVIEW is drawn at, handed down from the main actor's
    /// coordinator — see `setPreviewAngle`. 90 until it reports: a phone held
    /// upright, which is how a sheet is opened.
    private var previewAngle: CGFloat = 90
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
        defer {
            session.commitConfiguration()
            adoptPhotoDimensions()
        }
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
        // ⚠️ LAYER-LESS, AND THEREFORE FOR THE CAPTURE ANGLE ONLY: its preview
        // angle is 0 by contract. The preview's own coordinator is built on the
        // main actor with the layer — `AVCaptureSource.followPreviewRotation`.
        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        // Start on the wide lens, which is display factor 1.
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = Self.displayScale(of: device)
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }
    }

    /// The largest photograph the active format offers.
    ///
    /// ⚠️ **AFTER THE COMMIT, AND ONLY ONCE THE OUTPUT IS CONNECTED.** The
    /// preset picks the device's format at `commitConfiguration()`, and
    /// `maxPhotoDimensions` raises an exception for any size the ACTIVE format
    /// does not list — so read inside the configuration block it could name a
    /// size from the format being replaced, on a camera just switched to.
    private func adoptPhotoDimensions() {
        guard photoOutput.connection(with: .video) != nil,
              let largest = videoInput?.device.activeFormat.supportedMaxPhotoDimensions
                  .max(by: { $0.width * $0.height < $1.width * $1.height })
        else { return }
        photoOutput.maxPhotoDimensions = largest
    }

    /// ⚠️ THE ROTATION IS THE COORDINATOR'S, READ AT EACH CAPTURE — so a photo
    /// taken with the phone turned is level. Mirroring follows what the author
    /// SAW: a front-camera capture keeps the reflection the preview showed, the
    /// social cameras' convention.
    ///
    /// ⚠️ **TWO ANGLES, AND THE DATA OUTPUT TAKES THE PREVIEW'S.** Its frames
    /// ARE a preview — the drawn look and the filter cards. Given the capture
    /// angle, which follows gravity rather than the interface, they turned a
    /// quarter and were cropped by the aspect fill whenever the phone was held
    /// sideways over a portrait screen.
    private func applyConnections() {
        let captureAngle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        let mirrored = currentPosition == .front
        let outputs: [(AVCaptureOutput, CGFloat)] = [
            (photoOutput, captureAngle), (movieOutput, captureAngle), (dataOutput, previewAngle)
        ]
        for (output, angle) in outputs {
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
                zoomRange: 1...1, zoom: 1, hasFlash: false, deviceID: nil
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
            deviceID: device.uniqueID
        )
    }

    func switchTo(_ position: CapturePosition) async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                session.beginConfiguration()
                installCamera(position)
                applyConnections()
                session.commitConfiguration()
                adoptPhotoDimensions()
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

    /// The angle the preview is drawn at, from the main actor's coordinator.
    func setPreviewAngle(_ angle: CGFloat) {
        queue.async { [self] in
            previewAngle = angle
            guard let connection = dataOutput.connection(with: .video),
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
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
