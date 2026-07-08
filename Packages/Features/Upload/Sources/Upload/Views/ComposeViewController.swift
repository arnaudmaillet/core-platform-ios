import DesignSystem
import MediaPlayback
import PhotosUI
import UIKit
import UniformTypeIdentifiers

final class ComposeViewController: UIViewController {
    private let viewModel: ComposeViewModel

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let imageButton = UIButton(configuration: .gray())
    private let recordButton = UIButton(configuration: .gray())
    private let previewView = UIImageView()
    private let captionView = UITextView()
    private let captionPlaceholder = UILabel()
    private let errorLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private lazy var postButton = UIBarButtonItem(
        title: "Share",
        primaryAction: UIAction { [weak self] _ in self?.viewModel.post() }
    )

    init(viewModel: ComposeViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "New Post"
        configureNavigationBar()
        configureSubviews()

        viewModel.onStateChange = { [weak self] state in self?.render(state) }
        render(.editing)
    }

    private func configureNavigationBar() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem = postButton
    }

    private func configureSubviews() {
        contentStack.axis = .vertical
        contentStack.spacing = Spacing.lg
        contentStack.alignment = .fill

        var imageConfig = UIButton.Configuration.gray()
        imageConfig.title = "Add Photo or Video"
        imageConfig.image = UIImage(systemName: "photo.badge.plus")
        imageConfig.imagePadding = Spacing.sm
        imageButton.configuration = imageConfig
        imageButton.addAction(UIAction { [weak self] _ in self?.presentPicker() }, for: .primaryActionTriggered)

        var recordConfig = UIButton.Configuration.gray()
        recordConfig.title = "Record Video"
        recordConfig.image = UIImage(systemName: "video.badge.plus")
        recordConfig.imagePadding = Spacing.sm
        recordButton.configuration = recordConfig
        recordButton.addAction(UIAction { [weak self] _ in self?.presentCamera() }, for: .primaryActionTriggered)
        // No camera on the simulator (or an unauthorized/absent device) → hide it.
        recordButton.isHidden = !UIImagePickerController.isSourceTypeAvailable(.camera)

        previewView.contentMode = .scaleAspectFill
        previewView.clipsToBounds = true
        previewView.layer.cornerRadius = 12
        previewView.isHidden = true
        previewView.isUserInteractionEnabled = true
        previewView.addGestureRecognizer(UITapGestureRecognizer(
            target: self, action: #selector(presentPickerFromPreview)
        ))
        previewView.heightAnchor.constraint(equalToConstant: 260).isActive = true

        captionView.font = .preferredFont(forTextStyle: .body)
        captionView.adjustsFontForContentSizeCategory = true
        captionView.isScrollEnabled = false
        captionView.backgroundColor = .secondarySystemBackground
        captionView.layer.cornerRadius = 12
        captionView.textContainerInset = UIEdgeInsets(top: Spacing.md, left: Spacing.md, bottom: Spacing.md, right: Spacing.md)
        captionView.delegate = self
        captionView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        captionPlaceholder.text = "Write a caption…"
        captionPlaceholder.font = .preferredFont(forTextStyle: .body)
        captionPlaceholder.textColor = .placeholderText

        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        contentStack.addArrangedSubview(imageButton)
        contentStack.addArrangedSubview(recordButton)
        contentStack.addArrangedSubview(previewView)
        contentStack.addArrangedSubview(captionView)
        contentStack.addArrangedSubview(errorLabel)

        scrollView.pin(to: view, relativeTo: .safeArea)
        contentStack.constrain(in: scrollView) { [scrollView] _ in
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Spacing.lg)
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Spacing.lg)
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: Spacing.lg)
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg)
        }

        captionPlaceholder.constrain(in: captionView) { container in
            captionPlaceholder.topAnchor.constraint(equalTo: container.topAnchor, constant: Spacing.md)
            captionPlaceholder.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Spacing.md + 4)
        }

        spinner.hidesWhenStopped = true
        navigationItem.titleView = spinner
    }

    private func presentPicker() {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Records a new video with the camera. `UIImagePickerController` presents
    /// the system camera + the mic/camera permission prompts; the recorded clip
    /// funnels into the same `PickedVideo` path as a library selection.
    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func presentPickerFromPreview() {
        presentPicker()
    }

    private func render(_ state: ComposeViewModel.State) {
        switch state {
        case .editing:
            postButton.isEnabled = viewModel.canPost
            spinner.stopAnimating()
        case .uploading:
            postButton.isEnabled = false
            spinner.startAnimating()
            errorLabel.isHidden = true
            view.endEditing(true)
        case .finished:
            dismiss(animated: true)
        case .failed(let message):
            postButton.isEnabled = viewModel.canPost
            spinner.stopAnimating()
            errorLabel.text = message
            errorLabel.isHidden = false
        }
    }
}

// MARK: - PHPicker

extension ComposeViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }

        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            loadPickedVideo(from: provider)
        } else if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let image = object as? UIImage else { return }
                Task { @MainActor in self?.applyPickedImage(image) }
            }
        }
    }

    /// Copies the picked movie out of the (soon-deleted) provider sandbox into
    /// our temp dir, hands the URL to the view model, and shows a poster frame.
    private func loadPickedVideo(from provider: NSItemProvider) {
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let url else { return }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                return
            }
            Task { @MainActor in self?.applyPickedVideo(dest) }
        }
    }

    private func applyPickedImage(_ image: UIImage) {
        viewModel.setImage(image)
        previewView.image = image
        previewView.isHidden = false
        var config = imageButton.configuration
        config?.title = "Change Photo or Video"
        imageButton.configuration = config
        postButton.isEnabled = viewModel.canPost
    }

    private func applyPickedVideo(_ url: URL) {
        viewModel.setVideo(url)
        previewView.image = nil
        previewView.isHidden = false
        var config = imageButton.configuration
        config?.title = "Change Photo or Video"
        imageButton.configuration = config
        postButton.isEnabled = viewModel.canPost
        // Poster frame for the preview (best-effort, async).
        Task { @MainActor in
            let poster = await VideoExporter().posterImage(for: url)
            if self.viewModel.pickedVideoURL == url { self.previewView.image = poster }
        }
    }
}

// MARK: - Camera capture

extension ComposeViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        guard let url = info[.mediaURL] as? URL else { return }
        // The recorded file is in a temp location the picker may reclaim — copy it.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorded-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            return
        }
        applyPickedVideo(dest)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

// MARK: - Caption

extension ComposeViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        viewModel.caption = textView.text
        captionPlaceholder.isHidden = !textView.text.isEmpty
        postButton.isEnabled = viewModel.canPost
    }
}
