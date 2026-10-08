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

@MainActor
final class ThreadPhotoViewerController: UIViewController, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let url: URL?
    private let pipeline: ImagePipeline?

    init(image: UIImage?, url: URL?, pipeline: ImagePipeline?) {
        self.url = url
        self.pipeline = pipeline
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

        if imageView.image == nil, let url, let pipeline {
            Task { [weak self] in
                let image = try? await pipeline.image(for: url)
                self?.imageView.image = image
            }
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func tapped() {
        guard scrollView.zoomScale <= 1 else {
            scrollView.setZoomScale(1, animated: true)
            return
        }
        dismiss(animated: true)
    }
}
