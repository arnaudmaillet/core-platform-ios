import CoreMedia
import CoreModels
import DesignSystem
import UIKit

/// A full-screen snap cell: cover-fit media under a bottom scrim, with the
/// author, caption and engagement controls overlaid. Text-only posts drop the
/// media and show a gradient backdrop instead.
///
/// It reuses `FeedItemDisplayModel` as-is — only the fields relevant to a
/// full-bleed layout (`mediaURL`, `avatarURL`, author text, caption string) are
/// read; the precomputed heights are ignored because every cell is bounds-sized.
/// Captions are re-styled here (white-on-scrim) on the main thread, which is
/// free when only one or two cells are ever alive at once.
final class SnapFeedCell: UICollectionViewCell, SnapCellLifecycle {
    static let reuseIdentifier = "SnapFeedCell"

    private let mediaView = UIImageView()
    private let scrimView = GradientView(colors: [.clear, UIColor.black.withAlphaComponent(0.75)])
    private let textOnlyBackground = GradientView(
        colors: [UIColor(red: 0.15, green: 0.16, blue: 0.24, alpha: 1),
                 UIColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1)]
    )

    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()
    private let captionLabel = UILabel()

    private let likeButton = UIButton(configuration: .plain())
    private let likeCountLabel = UILabel()

    /// Set by the view controller; called on tap with the represented post.
    var onLikeTapped: ((PostID) -> Void)?
    /// Called when the author's avatar or name is tapped.
    var onAuthorTapped: ((ProfileID) -> Void)?

    private var representedID: PostID?
    private var authorID: ProfileID?
    private var imageTasks: [Task<Void, Never>] = []
    private var isActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        mediaView.contentMode = .scaleAspectFill
        mediaView.clipsToBounds = true

        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 18
        avatarView.backgroundColor = .darkGray
        avatarView.contentMode = .scaleAspectFill
        avatarView.widthAnchor.constraint(equalToConstant: 36).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: 36).isActive = true

        nameLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        nameLabel.textColor = .white
        metaLabel.font = .preferredFont(forTextStyle: .footnote)
        metaLabel.textColor = UIColor.white.withAlphaComponent(0.75)

        captionLabel.numberOfLines = 4
        captionLabel.textColor = .white

        // Legibility over arbitrary media, independent of the scrim.
        for label in [nameLabel, metaLabel, captionLabel] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.5
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
        }

        // Avatar + name route to the author's profile.
        for view in [avatarView, nameLabel] {
            view.isUserInteractionEnabled = true
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
        }

        var likeConfig = UIButton.Configuration.plain()
        likeConfig.image = UIImage(systemName: "heart")
        likeConfig.baseForegroundColor = .white
        likeButton.configuration = likeConfig
        likeButton.addAction(UIAction { [weak self] _ in
            guard let id = self?.representedID else { return }
            self?.onLikeTapped?(id)
        }, for: .primaryActionTriggered)

        likeCountLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        likeCountLabel.textColor = .white
        likeCountLabel.textAlignment = .center

        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        textOnlyBackground.pin(to: contentView)
        mediaView.pin(to: contentView)

        scrimView.isUserInteractionEnabled = false
        scrimView.constrain(in: contentView) { parent in
            scrimView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            scrimView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            scrimView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            scrimView.heightAnchor.constraint(equalTo: parent.heightAnchor, multiplier: 0.5)
        }

        // Author + caption, bottom-left, inset from the safe area.
        let header = UIStackView(arrangedSubviews: [avatarView, headerText()])
        header.axis = .horizontal
        header.spacing = Spacing.sm
        header.alignment = .center

        let leftStack = UIStackView(arrangedSubviews: [header, captionLabel])
        leftStack.axis = .vertical
        leftStack.spacing = Spacing.sm
        leftStack.alignment = .leading
        leftStack.constrain(in: contentView) { parent in
            leftStack.leadingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.leadingAnchor, constant: Spacing.lg)
            leftStack.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.lg)
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -72)
        }

        // Engagement rail, bottom-right (TikTok-style vertical stack).
        let likeStack = UIStackView(arrangedSubviews: [likeButton, likeCountLabel])
        likeStack.axis = .vertical
        likeStack.spacing = Spacing.xs
        likeStack.alignment = .center
        likeStack.constrain(in: contentView) { parent in
            likeStack.trailingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -Spacing.md)
            likeStack.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.lg)
        }
    }

    private func headerText() -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [nameLabel, metaLabel])
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        return stack
    }

    // MARK: - Configuration

    func configure(with model: FeedItemDisplayModel, engagement: FeedViewModel.EngagementState, pipeline: ImagePipeline) {
        representedID = model.id
        authorID = model.authorID
        updateEngagement(engagement)

        nameLabel.text = model.authorName
        metaLabel.text = model.metaText

        let captionText = model.caption?.attributed.string
        captionLabel.text = captionText
        captionLabel.isHidden = (captionText?.isEmpty ?? true)

        let hasMedia = model.mediaURL != nil
        mediaView.isHidden = !hasMedia
        scrimView.isHidden = !hasMedia
        textOnlyBackground.isHidden = hasMedia
        // Text-only posts lean on the caption, so give it more room and weight.
        captionLabel.numberOfLines = hasMedia ? 4 : 8
        captionLabel.font = hasMedia
            ? .preferredFont(forTextStyle: .body)
            : UIFont.preferredFont(forTextStyle: .title2).withWeight(.semibold)

        avatarView.image = nil
        mediaView.image = nil
        mediaView.transform = .identity

        loadImage(model.avatarURL, into: avatarView, expecting: model.id, pipeline: pipeline)
        if hasMedia {
            loadImage(model.mediaURL, into: mediaView, expecting: model.id, pipeline: pipeline)
        }
    }

    /// Updates only the engagement rail — live counter ticks and optimistic
    /// like toggles. Never relayouts.
    func updateEngagement(_ state: FeedViewModel.EngagementState) {
        likeCountLabel.text = Self.countText(state.likeCount)
        var config = likeButton.configuration
        config?.image = UIImage(systemName: state.isLiked ? "heart.fill" : "heart")
        config?.baseForegroundColor = state.isLiked ? .systemRed : .white
        likeButton.configuration = config
    }

    private func loadImage(_ url: URL?, into imageView: UIImageView, expecting id: PostID, pipeline: ImagePipeline) {
        guard let url else { return }
        imageTasks.append(Task { [weak self, weak imageView] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.representedID == id else { return }
            imageView?.image = image
            // If the media arrives after activation, kick the motion now.
            if imageView === self.mediaView, self.isActive {
                self.startKenBurns()
            }
        })
    }

    @objc private func authorTapped() {
        guard let authorID else { return }
        onAuthorTapped?(authorID)
    }

    private static func countText(_ count: Int64) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : String(count)
    }

    // MARK: - SnapCellLifecycle

    func willBecomeActive() {
        guard !isActive else { return }
        isActive = true
        startKenBurns()
    }

    func didResignActive() {
        guard isActive else { return }
        isActive = false
        stopKenBurns()
    }

    /// Phase 1's visible proof that activation works: a slow zoom on the active
    /// page's media. Phase 2 replaces this body with `player.play()`.
    private func startKenBurns() {
        guard mediaView.image != nil, !mediaView.isHidden else { return }
        mediaView.layer.removeAllAnimations()
        UIView.animate(withDuration: 8, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
            self.mediaView.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        }
    }

    private func stopKenBurns() {
        mediaView.layer.removeAllAnimations()
        UIView.performWithoutAnimation { self.mediaView.transform = .identity }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isActive = false
        stopKenBurns()
        representedID = nil
        authorID = nil
        for task in imageTasks { task.cancel() }
        imageTasks.removeAll()
        avatarView.image = nil
        mediaView.image = nil
    }
}

/// A view backed by a `CAGradientLayer`, sized automatically with its bounds.
private final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

    init(colors: [UIColor],
         startPoint: CGPoint = CGPoint(x: 0.5, y: 0),
         endPoint: CGPoint = CGPoint(x: 0.5, y: 1)) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        gradientLayer.colors = colors.map(\.cgColor)
        gradientLayer.startPoint = startPoint
        gradientLayer.endPoint = endPoint
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
