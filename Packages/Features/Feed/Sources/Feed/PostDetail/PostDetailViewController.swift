import MediaCore
import DesignSystem
import FeedInterface
import UIKit

final class PostDetailViewController: UIViewController {
    private enum Metrics {
        static let avatarSize: CGFloat = 44
    }

    private let viewModel: PostDetailViewModel
    private let imagePipeline: ImagePipeline
    private let mode: PostDetailMode

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

    private let commentsHeaderLabel = UILabel()
    private let commentsStack = UIStackView()
    private let composeBar = UIView()
    private let composeField = UITextField()
    private let sendButton = UIButton(configuration: .plain())
    private let composeSpinner = UIActivityIndicatorView(style: .medium)

    private var mediaAspectConstraint: NSLayoutConstraint?
    private var imageTasks: [Task<Void, Never>] = []

    init(viewModel: PostDetailViewModel, imagePipeline: ImagePipeline, mode: PostDetailMode = .full) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        for task in imageTasks { task.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = mode == .commentsOnly ? "Comments" : "Post"
        view.backgroundColor = .systemBackground
        configureViews()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onEngagementChange = { [weak self] state in self?.renderEngagement(state) }
        viewModel.onCommentsChange = { [weak self] state in self?.renderComments(state) }
        viewModel.onComposingChange = { [weak self] composing in self?.renderComposing(composing) }
        render(.loading)
        viewModel.viewDidLoad()
    }

    // MARK: - Setup

    private func configureViews() {
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        scrollView.refreshControl = refreshControl
        configureComposeBar()
        // Scroll view fills above the compose bar, which tracks the keyboard.
        scrollView.constrain(in: view) { parent in
            scrollView.topAnchor.constraint(equalTo: parent.topAnchor)
            scrollView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            scrollView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            scrollView.bottomAnchor.constraint(equalTo: composeBar.topAnchor)
        }

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

        commentsHeaderLabel.text = "Comments"
        commentsHeaderLabel.font = .preferredFont(forTextStyle: .headline)
        commentsHeaderLabel.adjustsFontForContentSizeCategory = true
        commentsHeaderLabel.textColor = .label
        commentsHeaderLabel.isHidden = true

        commentsStack.axis = .vertical
        commentsStack.spacing = Spacing.lg

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = Spacing.md
        // The post section (header/media/engagement) is grouped so comments-only
        // mode can hide it as a unit — `configure()` later toggles the inner
        // views' `isHidden`, which is moot under a hidden parent.
        let postSectionStack = UIStackView(arrangedSubviews: [authorRow, captionLabel, mediaView, timestampLabel, likeRow])
        postSectionStack.axis = .vertical
        postSectionStack.spacing = Spacing.md
        contentStack.addArrangedSubview(postSectionStack)
        contentStack.addArrangedSubview(commentsHeaderLabel)
        contentStack.addArrangedSubview(commentsStack)
        contentStack.setCustomSpacing(Spacing.lg, after: postSectionStack)

        // Comments-only (from the snap feed, where the post is already on-screen):
        // drop the post header/media/engagement, keep comments + the compose bar.
        if mode == .commentsOnly {
            postSectionStack.isHidden = true
        }

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

    private func configureComposeBar() {
        composeBar.backgroundColor = .systemBackground

        composeField.placeholder = "Add a comment…"
        composeField.borderStyle = .roundedRect
        composeField.returnKeyType = .send
        composeField.delegate = self
        composeField.font = .preferredFont(forTextStyle: .body)
        composeField.adjustsFontForContentSizeCategory = true

        var sendConfig = UIButton.Configuration.plain()
        sendConfig.image = UIImage(systemName: "arrow.up.circle.fill")
        sendConfig.contentInsets = .zero
        sendButton.configuration = sendConfig
        sendButton.addAction(UIAction { [weak self] _ in self?.sendComment() }, for: .primaryActionTriggered)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        composeSpinner.hidesWhenStopped = true

        let row = UIStackView(arrangedSubviews: [composeField, sendButton, composeSpinner])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        row.pin(to: composeBar, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg
        ))

        let separator = UIView()
        separator.backgroundColor = .separator

        view.addSubview(composeBar)
        composeBar.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        composeBar.addSubview(separator)
        NSLayoutConstraint.activate([
            composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Tracks the keyboard; sits at the safe-area bottom when dismissed.
            composeBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            separator.topAnchor.constraint(equalTo: composeBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: composeBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: composeBar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    private func sendComment() {
        let text = composeField.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        composeField.text = ""
        viewModel.submitComment(text)
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

    private func renderComments(_ state: PostDetailViewModel.CommentsState) {
        // Comments-only contexts already carry a "Comments" title (the nav
        // bar when pushed, the panel header when sheeted) — the inline
        // section header would duplicate it.
        commentsHeaderLabel.isHidden = mode == .commentsOnly
        guard case .loaded(let models) = state else { return }
        commentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if models.isEmpty {
            let empty = UILabel()
            empty.text = "No comments yet. Be the first."
            empty.font = .preferredFont(forTextStyle: .subheadline)
            empty.adjustsFontForContentSizeCategory = true
            empty.textColor = .secondaryLabel
            commentsStack.addArrangedSubview(empty)
        } else {
            for model in models {
                commentsStack.addArrangedSubview(CommentRowView(model: model))
            }
            cascadeCommentsInIfFirstLoad()
        }
    }

    private var didCascadeComments = false

    /// The first loaded render in comments-only mode rises in with a short
    /// per-row stagger, so under the snap feed's comments panel the stream
    /// reads as materializing beneath the media rather than arriving
    /// pre-attached to the panel. One-shot: refreshes and composed-comment
    /// re-renders swap content statically.
    private func cascadeCommentsInIfFirstLoad() {
        guard mode == .commentsOnly, !didCascadeComments, view.window != nil else { return }
        didCascadeComments = true
        view.layoutIfNeeded()
        for (index, row) in commentsStack.arrangedSubviews.enumerated() {
            row.alpha = 0
            row.transform = CGAffineTransform(translationX: 0, y: 14)
            UIView.animate(
                withDuration: 0.3,
                delay: 0.05 + Double(min(index, 10)) * 0.04,
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                row.alpha = 1
                row.transform = .identity
            }
        }
    }

    private func renderComposing(_ composing: Bool) {
        composeField.isEnabled = !composing
        sendButton.isHidden = composing
        if composing { composeSpinner.startAnimating() } else { composeSpinner.stopAnimating() }
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

extension PostDetailViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendComment()
        return false
    }
}
