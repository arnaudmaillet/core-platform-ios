import AVKit
import DesignSystem
import FeedInterface
import MediaCore
import UIKit

/// A message's photo, full screen (#681): the picture whole on black, pinch
/// to look closer, ✕ (or a tap) to close. A video opens in the system
/// player instead (`ThreadMediaViewer.make`).
@MainActor
enum ThreadMediaViewer {
    /// The screen for `media`: the photo viewer, or the system player for a
    /// video with a URL. Nil when there is nothing to open (a video still
    /// uploading).
    static func make(
        _ media: ConversationThreadMedia, shownImage: UIImage?, pipeline: ImagePipeline?
    ) -> UIViewController? {
        switch media.kind {
        case .video:
            guard let url = media.url else { return nil }
            let player = AVPlayerViewController()
            player.player = AVPlayer(url: url)
            player.modalPresentationStyle = .fullScreen
            player.player?.play()
            return player
        case .image:
            let viewer = ThreadPhotoViewerController(
                image: media.preview ?? shownImage, url: media.url, pipeline: pipeline
            )
            viewer.modalPresentationStyle = .fullScreen
            viewer.modalTransitionStyle = .crossDissolve
            return viewer
        }
    }
}

/// The photo, full screen, in the charter's states (P8, P10, P11, #831):
///
/// - **Content at once when the picture is at hand**: the one picked, the one
///   the bubble shows, or the image cache's — read synchronously, so a photo
///   already seen opens on itself rather than on a black frame.
/// - **Loading**: the full-screen rule (#1764, #1772): the centred loader,
///   after the kit's grace (`LoaderGate`), never a bone; the picture lands
///   through the slot (`CoverSlot`), dissolved in.
/// - **Failed**: the reason and Try Again (`EmptyStateView`, dark on black,
///   as the whole viewer is), which loads again. A photo with no address at
///   all fails without the offer: there is nothing to try.
///
/// There is no empty state: a message's photo is always something.
@MainActor
final class ThreadPhotoViewerController: UIViewController, UIScrollViewDelegate {
    enum Phase: Equatable {
        case loading
        case content
        case failed
    }

    private(set) var phase: Phase
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    /// The picture's slot — no bone: a full-screen wait is the loader's.
    private lazy var cover: CoverSlot = {
        let cover = CoverSlot(view: imageView, size: .full, showsSkeleton: false)
        cover.onLoaded = { [weak self] in self?.landed() }
        cover.onFailed = { [weak self] in self?.failed() }
        return cover
    }()
    private let loader = AppLoaderView(size: .large)
    private lazy var loaderGate = LoaderGate(loader: loader, minimum: 0)
    private let failedState = EmptyStateView()
    private let url: URL?
    private let pipeline: ImagePipeline?

    init(image: UIImage?, url: URL?, pipeline: ImagePipeline?) {
        self.url = url
        self.pipeline = pipeline
        phase = image != nil ? .content : (url != nil && pipeline != nil ? .loading : .failed)
        super.init(nibName: nil, bundle: nil)
        imageView.image = image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        // Over the picture, under ✕: the loader and the failed state stand
        // where the photo will, and the way out stays on top of both.
        loader.hidesWhenStopped = true
        loader.isAccessibilityElement = true
        loader.accessibilityLabel = "Loading photo"
        loader.constrain(in: view) { parent in
            loader.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            loader.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        failedState.pin(to: view)

        let close = UIButton(configuration: .glass())
        close.configuration?.image = UIImage(systemName: "xmark")
        close.accessibilityLabel = "Close"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm),
            close.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Spacing.md),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        scrollView.addGestureRecognizer(tap)

        switch phase {
        case .content:
            failedState.isHidden = true
        case .loading:
            failedState.isHidden = true
            load()
        case .failed:
            showFailed()
        }
    }

    /// Loads the picture through the slot — at once when the cache holds
    /// it, else under the loader; Try Again comes back here.
    private func load() {
        guard let url, let pipeline else { return }
        phase = .loading
        cover.load(url, pipeline: pipeline, item: url)
        guard imageView.image == nil else { return landed() }
        loaderGate.begin { [weak self] in self?.phase == .loading }
    }

    private func landed() {
        phase = .content
        loaderGate.cancel()
    }

    private func failed() {
        phase = .failed
        loaderGate.cancel()
        showFailed()
        // VoiceOver was on "Loading photo"; it is taken to what replaced it.
        UIAccessibility.post(notification: .layoutChanged, argument: failedState)
    }

    private func showFailed() {
        let canRetry = url != nil && pipeline != nil
        failedState.configure(
            symbolName: "exclamationmark.triangle",
            title: "Couldn't load this photo",
            subtitle: canRetry ? "Check your connection and try again." : nil,
            actionTitle: canRetry ? "Try Again" : nil,
            actionHandler: canRetry ? { [weak self] in self?.retry() } : nil
        )
        failedState.isHidden = false
    }

    private func retry() {
        failedState.isHidden = true
        load()
    }

    #if DEBUG
    /// The picture on screen now — what a test reads.
    var debugImage: UIImage? { imageView.isHidden ? nil : imageView.image }
    /// Whether the wait is announced — the loader up, or its grace running.
    var debugAnnouncesWait: Bool { loaderGate.isShowing || loaderGate.isArmed }
    /// The failed state while it shows, for a test to read and press Try
    /// Again on.
    var debugFailedState: EmptyStateView? { failedState.isHidden ? nil : failedState }
    #endif

    /// Only a picture zooms: a pinch over the loader or the failed state
    /// does nothing.
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        phase == .content ? imageView : nil
    }

    @objc private func tapped() {
        guard scrollView.zoomScale <= 1 else {
            scrollView.setZoomScale(1, animated: true)
            return
        }
        dismiss(animated: true)
    }
}
