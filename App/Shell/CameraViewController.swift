import AVFoundation
import UIKit

/// The capture surface: where "Camera" in the tab bar's "+" menu lands (see
/// `CreateTabItem`). One screen, no capture controls yet — the preview, the
/// session and a way out, so the controls can be designed on top of it later.
///
/// It used to be the ROOT of a Camera tab, which is why it is our own view
/// rather than `UIImagePickerController`: a capture session here is one
/// screen whose controls can be anything (a TikTok/Instagram-style capture
/// surface), where Apple's picker chrome cannot be customised at all. The tab
/// is gone; the screen is now PRESENTED, which is what the close button is
/// for — a root never needed one.
///
/// ⚠️ THE PREVIEW IS BLACK ON THE SIMULATOR, ALWAYS, and that is not a defect
/// here. Measured:
///
///     [camera] authorised=3 devices=0 [] default=nil
///     [camera] inputs=0 running=true
///
/// AVFoundation exposes NO capture device on a simulator, so the session runs
/// with zero inputs and the layer has nothing to draw. Do not read that black
/// screen as a broken preview, and do not "fix" it by adding a device search —
/// there is nothing to find.
///
/// ⚠️ AND DO NOT CONCLUDE FROM `UIImagePickerController` THAT THERE IS A CAMERA.
/// iOS 26's simulator does show Apple's picker with a synthetic feed, which is
/// simulated at the UIKit level; it says nothing about `AVCaptureDevice`. That
/// contradiction is exactly what this note exists to settle. Verifying the
/// preview needs hardware.
final class CameraViewController: UIViewController {
    private let session = AVCaptureSession()
    /// Configuration and start/stop are documented as blocking; they belong off
    /// the main thread or they land as a hitch on the presentation.
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false

    private lazy var closeButton: UIButton = {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: "xmark")
        let button = UIButton(
            configuration: configuration,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        button.accessibilityLabel = "Close"
        return button
    }()

    init() {
        super.init(nibName: nil, bundle: nil)
        // Full screen, not a sheet: a capture surface wants every pixel, and a
        // sheet's swipe-down would compete with whatever gestures the controls
        // grow.
        modalPresentationStyle = .fullScreen
        // Always dark, whatever the system appearance: the ground is a camera
        // preview, black until it has frames, so the glass button and the
        // status bar are drawn for a dark scene.
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        // Added after the preview layer, so it draws above it.
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalTo: closeButton.widthAnchor)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startIfAuthorised()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A running session holds the camera and burns power; the screen is a
        // place the viewer leaves, so it stops when they do.
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func startIfAuthorised() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                Task { @MainActor in self?.configureAndStart() }
            }
        case .denied, .restricted:
            // Nothing to show. Deliberately silent for now: the empty state
            // belongs with the controls, which are not designed yet.
            break
        @unknown default:
            break
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.isConfigured = true
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                if let device = AVCaptureDevice.default(
                    .builtInWideAngleCamera, for: .video, position: .back
                ) ?? AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                self.session.commitConfiguration()
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }
}
