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
                image: media.preview ?? shownImage, url: media.url, pipeline: pipeline,
                aspectRatio: media.aspectRatio
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
/// - **Loading**: a bone at the photo's own shape on the black, cross-faded
///   to the picture when it lands (`crossfadeSkeleton`), never a snap.
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
    private let placeholder = SkeletonBoneView(rounding: .fixed(0))
    private let failedState = EmptyStateView()
    private let url: URL?
    private let pipeline: ImagePipeline?
    /// Width over height, as the bubble reads it: the bone's shape.
    private let aspectRatio: CGFloat?
    private var loadTask: Task<Void, Never>?

    init(image: UIImage?, url: URL?, pipeline: ImagePipeline?, aspectRatio: CGFloat? = nil) {
        self.url = url
        self.pipeline = pipeline
        self.aspectRatio = aspectRatio
        let seed = image ?? url.flatMap { pipeline?.cachedImage(for: $0) }
        phase = seed != nil ? .content : (url != nil && pipeline != nil ? .loading : .failed)
        super.init(nibName: nil, bundle: nil)
        imageView.image = seed
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
        // Over the picture, under ✕: the bone and the failed state stand
        // where the photo will, and the way out stays on top of both.
        view.addSubview(placeholder)
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
            placeholder.isHidden = true
            failedState.isHidden = true
        case .loading:
            imageView.isHidden = true
            failedState.isHidden = true
            load()
        case .failed:
            imageView.isHidden = true
            placeholder.isHidden = true
            showFailed()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        placeholder.frame = Self.fittedRect(aspectRatio: aspectRatio, in: view.bounds)
    }

    /// The photo's shape fitted to `bounds` as `.scaleAspectFit` draws it, so
    /// the bone stands where the picture will. Square when the shape is not
    /// known.
    static func fittedRect(aspectRatio: CGFloat?, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let ratio = aspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
        var size = CGSize(width: bounds.width, height: bounds.width / ratio)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height * ratio, height: bounds.height)
        }
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    /// Fetches the picture behind the bone; Try Again comes back here.
    private func load() {
        guard let url, let pipeline else { return }
        phase = .loading
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image: UIImage?
            do {
                image = try await pipeline.image(for: url)
            } catch {
                image = nil
            }
            guard let self, !Task.isCancelled else { return }
            if let image {
                phase = .content
                imageView.image = image
                placeholder.crossfadeSkeleton(to: imageView)
            } else {
                phase = .failed
                showFailed()
                placeholder.crossfadeSkeleton(to: failedState)
            }
        }
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
        placeholder.showSkeleton()
        load()
    }

    #if DEBUG
    /// The picture on screen now — what a test reads.
    var debugImage: UIImage? { imageView.isHidden ? nil : imageView.image }
    /// Whether the bone stands in for the picture — what a test reads.
    var debugShowsPlaceholder: Bool { !placeholder.isHidden && placeholder.alpha > 0 }
    /// The failed state while it shows, for a test to read and press Try
    /// Again on.
    var debugFailedState: EmptyStateView? { failedState.isHidden ? nil : failedState }
    #endif

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func tapped() {
        guard scrollView.zoomScale <= 1 else {
            scrollView.setZoomScale(1, animated: true)
            return
        }
        dismiss(animated: true)
    }
}
