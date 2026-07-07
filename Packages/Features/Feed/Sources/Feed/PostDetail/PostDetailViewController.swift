import CoreMedia
import DesignSystem
import UIKit

final class PostDetailViewController: UIViewController {
    private enum Metrics {
        static let avatarSize: CGFloat = 44
    }

    private let viewModel: PostDetailViewModel
    private let imagePipeline: ImagePipeline

    private let scrollView = UIScrollView()
    private let refreshControl = UIRefreshControl()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let contentStack = UIStackView()

    private let avatarView = UIView()
    private let avatarImageView = UIImageView()
    private let monogramLabel = UILabel()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let captionLabel = UILabel()
    private let mediaView = UIImageView()
    private let timestampLabel = UILabel()
    private let likeButton = UIButton(configuration: .plain())
    private let likeCountLabel = UILabel()

    private var mediaAspectConstraint: NSLayoutConstraint?
    private var imageTasks: [Task<Void, Never>] = []

    init(viewModel: PostDetailViewModel, imagePipeline: ImagePipeline) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        for task in imageTasks { task.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Post"
        view.backgroundColor = .systemBackground
        configureViews()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onEngagementChange = { [weak self] state in self?.renderEngagement(state) }
        render(.loading)
        viewModel.viewDidLoad()
    }

    // MARK: - Setup

    private func configureViews() {
        scrollView.alwaysBounceVertical = true
        scrollView.pin(to: view)
        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        scrollView.refreshControl = refreshControl

        // Author row: avatar + name/handle, tappable → profile.
        avatarView.backgroundColor = .tertiarySystemFill
        avatarView.layer.cornerRadius = Metrics.avatarSize / 2
        avatarView.clipsToBounds = true
        monogramLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        monogramLabel.textColor = .secondaryLabel
        monogramLabel.textAlignment = .center
        monogramLabel.pin(to: avatarView)
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.pin(to: avatarView) // overlays the monogram once loaded

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        handleLabel.font = .preferredFont(forTextStyle: .subheadline)
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = .secondaryLabel

        let nameStack = UIStackView(arrangedSubviews: [nameLabel, handleLabel])
        nameStack.axis = .vertical
        nameStack.spacing = 2
        let authorRow = UIStackView(arrangedSubviews: [avatarView, nameStack])
        authorRow.axis = .horizontal
        authorRow.alignment = .center
        authorRow.spacing = Spacing.md
        authorRow.isUserInteractionEnabled = true
        authorRow.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))

        captionLabel.font = .preferredFont(forTextStyle: .body)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .label
        captionLabel.numberOfLines = 0

        mediaView.clipsToBounds = true
        mediaView.layer.cornerRadius = 12
        mediaView.backgroundColor = .tertiarySystemFill
        mediaView.contentMode = .scaleAspectFill

        timestampLabel.font = .preferredFont(forTextStyle: .footnote)
        timestampLabel.adjustsFontForContentSizeCategory = true
        timestampLabel.textColor = .secondaryLabel

        var likeConfig = UIButton.Configuration.plain()
        likeConfig.image = UIImage(systemName: "heart")
        likeConfig.contentInsets = .zero
        likeButton.configuration = likeConfig
        likeButton.addAction(UIAction { [weak self] _ in self?.viewModel.toggleLike() }, for: .primaryActionTriggered)
        likeCountLabel.font = .preferredFont(forTextStyle: .subheadline)
        likeCountLabel.textColor = .secondaryLabel
        let likeRow = UIStackView(arrangedSubviews: [likeButton, likeCountLabel, UIView()])
        likeRow.axis = .horizontal
        likeRow.alignment = .center
        likeRow.spacing = Spacing.xs

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = Spacing.md
        contentStack.addArrangedSubview(authorRow)
        contentStack.addArrangedSubview(captionLabel)
        contentStack.addArrangedSubview(mediaView)
        contentStack.addArrangedSubview(timestampLabel)
        contentStack.addArrangedSubview(likeRow)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        contentStack.constrain(in: scrollView) { _ in
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: Spacing.lg)
            contentStack.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: Spacing.lg)
            contentStack.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -Spacing.lg)
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Spacing.lg)
        }
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize)
        ])

        spinner.hidesWhenStopped = true
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.constrain(in: view) { parent in
            statusLabel.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            statusLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }

    @objc private func authorTapped() {
        viewModel.didTapAuthor()
    }

    // MARK: - Render

    private func render(_ phase: PostDetailViewModel.Phase) {
        switch phase {
        case .loading:
            if !refreshControl.isRefreshing { spinner.startAnimating() }
            scrollView.isHidden = true
            statusLabel.isHidden = true
        case .content(let model):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            statusLabel.isHidden = true
            scrollView.isHidden = false
            configure(model)
        case .failed(let message):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            scrollView.isHidden = true
            statusLabel.text = message
            statusLabel.isHidden = false
        }
    }

    private func configure(_ model: PostDetailDisplayModel) {
        monogramLabel.text = model.avatarMonogram
        nameLabel.text = model.authorName
        handleLabel.text = model.handle
        captionLabel.text = model.caption
        captionLabel.isHidden = !model.hasCaption
        timestampLabel.text = model.timestampText

        mediaView.isHidden = !model.hasMedia
        mediaAspectConstraint?.isActive = false
        if model.hasMedia {
            let constraint = mediaView.heightAnchor.constraint(
                equalTo: mediaView.widthAnchor,
                multiplier: 1 / max(0.5, model.mediaAspectRatio)
            )
            constraint.isActive = true
            mediaAspectConstraint = constraint
        }

        loadAvatar(model.avatarURL)
        loadMedia(model.mediaURL)
    }

    private func renderEngagement(_ state: PostDetailViewModel.EngagementState) {
        likeCountLabel.text = state.likeCount > 0 ? "\(state.likeCount)" : ""
        var config = likeButton.configuration
        config?.image = UIImage(systemName: state.isLiked ? "heart.fill" : "heart")
        config?.baseForegroundColor = state.isLiked ? .systemRed : .secondaryLabel
        likeButton.configuration = config
    }

    // MARK: - Images

    private func loadAvatar(_ url: URL?) {
        avatarImageView.image = nil
        guard let url else { return }
        let pipeline = imagePipeline
        imageTasks.append(Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            self?.avatarImageView.image = image
        })
    }

    private func loadMedia(_ url: URL?) {
        guard let url else { return }
        let pipeline = imagePipeline
        imageTasks.append(Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            self?.mediaView.image = image
        })
    }
}
