import AVFoundation
import CoreNavigation
import UIKit

/// Owns the Camera tab: the detached, trailing item of the bar.
///
/// # Why this is a `UISearchTab`
///
/// The bar's fifth item sits apart, in its own bubble. That detachment is not
/// something a tab asks for on iPhone — it is something the SYSTEM does for one
/// type. Measured both ways on a compact device:
///
///   - a plain `UITab` with `preferredPlacement = .pinned` lands INSIDE the
///     same bubble as the other four. The placement is honoured as an ORDER,
///     trailing-most, not as a separation. (`.pinned` is documented on the
///     iPad sidebar page, where bars are customisable; a compact bar has no
///     customisation to place against.)
///   - a `UISearchTab` is separated, and Apple documents it as a property of
///     the type rather than of the placement: "In addition to configuring a tab
///     with a system-provided symbol for search, UISearchTab also automatically
///     separates the search tab from other tabs when the tab bar is compact."
///
/// So the bubble comes from the type. `UISearchTab`'s own initialiser gives "a
/// system localized title and image" and takes no parameters for them — but
/// `title` and `image` are `{ get set }` on `UITab` and are NOT redeclared
/// read-only by the subclass, so they are assigned here. That is the documented
/// surface, used as documented.
///
/// ⚠️ WHAT IT COSTS: the system still knows this as the search ROLE.
/// `UISearchTab.identifier` is system-assigned, so anything keyed on that
/// identifier sees "search". The search FIELD does not appear, and that is not
/// luck — UIKit renders it from the view controller's own
/// `navigationItem.searchController`, and this screen installs none.
@MainActor
final class CameraTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private(set) lazy var tab: UITab = {
        let tab = UISearchTab { [navigationController] _ in navigationController }
        tab.title = "Camera"
        tab.image = UIImage(systemName: "camera")
        return tab
    }()

    func start() {
        // ⚠️ THE CAMERA IS THE TAB'S ROOT, not something it presents.
        //
        // It was a blank view controller that put a `UIImagePickerController`
        // up on top, which is two screens: an empty one titled "Camera", and
        // Apple's picker over it. A capture session in the root view controller
        // is one screen — and it is OUR view, so the controls can be anything
        // (a TikTok/Instagram-style capture surface) instead of Apple's fixed
        // picker chrome, which cannot be customised at all.
        navigationController.viewControllers = [CameraViewController()]
        navigationController.setNavigationBarHidden(true, animated: false)
    }
}

/// The capture surface. One screen, no chrome yet — the preview and the session
/// only, so the controls can be designed on top of it later.
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
    /// the main thread or they land as a hitch on the tab switch.
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
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
        // A running session holds the camera and burns power; the tab is a
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
