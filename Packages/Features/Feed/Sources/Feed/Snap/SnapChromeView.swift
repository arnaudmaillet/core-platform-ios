import MediaCore
import CoreModels
import DesignSystem
import UIKit

/// The snap page's UI chrome — bottom scrim, author row, caption, and the
/// engagement rail — as one self-contained full-bleed overlay.
///
/// It exists twice per hero flight: embedded in every `SnapFeedCell` (the
/// live, interactive instance) and inside the transition's flying card (an
/// inert replica configured from the same display model). One scaffold, two
/// instances — the flight is pixel-identical to the landed page and the two
/// layouts can never fork, because there is only one layout.
///
/// Geometry is data-independent: labels fill in whenever `configure` runs
/// (possibly mid-flight, on a cold tap) without moving the scaffold.
final class SnapChromeView: UIView {
    private let scrimView = GradientView(colors: [.clear, UIColor.black.withAlphaComponent(0.75)])

    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()
    private let captionLabel = UILabel()

    private let likeButton = UIButton(configuration: .plain())
    private let likeCountLabel = UILabel()
    private let commentButton = UIButton(configuration: .plain())

    private let headerStack: UIStackView
    private let railStack: UIStackView

    /// Set by the owning cell; called on tap with the represented post/author.
    /// The flight replica leaves these nil and disables interaction entirely.
    var onLikeTapped: ((PostID) -> Void)?
    var onAuthorTapped: ((ProfileID) -> Void)?
    var onCommentTapped: ((PostID) -> Void)?

    /// Subtrees where a touch means "use the control", not "toggle playback" —
    /// consumed by the cell's tap arbitration.
    var interactionRoots: [UIView] { [railStack, headerStack] }

    private var representedID: PostID?
    private var authorID: ProfileID?
    private var avatarTask: Task<Void, Never>?

    override init(frame: CGRect) {
        let headerText = UIStackView(arrangedSubviews: [nameLabel, metaLabel])
        headerText.axis = .vertical
        headerText.spacing = 0
        headerText.alignment = .leading
        headerStack = UIStackView(arrangedSubviews: [avatarView, headerText])
        headerStack.axis = .horizontal
        headerStack.spacing = Spacing.sm
        headerStack.alignment = .center
        railStack = UIStackView(arrangedSubviews: [likeButton, likeCountLabel, commentButton])
        railStack.axis = .vertical
        railStack.spacing = Spacing.xs
        railStack.alignment = .center
        super.init(frame: frame)

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

        var commentConfig = UIButton.Configuration.plain()
        commentConfig.image = UIImage(systemName: "bubble.right")
        commentConfig.baseForegroundColor = .white
        commentButton.configuration = commentConfig
        commentButton.addAction(UIAction { [weak self] _ in
            guard let id = self?.representedID else { return }
            self?.onCommentTapped?(id)
        }, for: .primaryActionTriggered)

        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        scrimView.isUserInteractionEnabled = false
        scrimView.constrain(in: self) { parent in
            scrimView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            scrimView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            scrimView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            scrimView.heightAnchor.constraint(equalTo: parent.heightAnchor, multiplier: 0.5)
        }

        // Author + caption, bottom-left, inset from the safe area.
        let leftStack = UIStackView(arrangedSubviews: [headerStack, captionLabel])
        leftStack.axis = .vertical
        leftStack.spacing = Spacing.sm
        leftStack.alignment = .leading
        leftStack.constrain(in: self) { parent in
            leftStack.leadingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.leadingAnchor, constant: Spacing.lg)
            leftStack.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.lg)
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -72)
        }

        // Engagement rail, bottom-right (TikTok-style vertical stack): like +
        // count, then comment.
        railStack.setCustomSpacing(Spacing.md, after: likeCountLabel)
        railStack.constrain(in: self) { parent in
            railStack.trailingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -Spacing.md)
            railStack.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.lg)
        }
    }

    // MARK: - Configuration

    func configure(
        with model: FeedItemDisplayModel,
        engagement: FeedViewModel.EngagementState,
        pipeline: ImagePipeline
    ) {
        representedID = model.id
        authorID = model.authorID
        updateEngagement(engagement)

        nameLabel.text = model.authorName
        metaLabel.text = model.metaText

        let captionText = model.caption
        captionLabel.text = captionText
        captionLabel.isHidden = (captionText?.isEmpty ?? true)

        let hasMedia = model.mediaURL != nil
        scrimView.isHidden = !hasMedia
        // Text-only posts lean on the caption, so give it more room and weight.
        captionLabel.numberOfLines = hasMedia ? 4 : 8
        captionLabel.font = hasMedia
            ? .preferredFont(forTextStyle: .body)
            : UIFont.preferredFont(forTextStyle: .title2).withWeight(.semibold)

        avatarView.image = nil
        avatarTask?.cancel()
        if let url = model.avatarURL {
            let id = model.id
            avatarTask = Task { [weak self] in
                guard let image = try? await pipeline.image(for: url) else { return }
                guard let self, self.representedID == id else { return }
                self.avatarView.image = image
            }
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

    /// Cancels in-flight work and clears post-specific content (cell reuse).
    func reset() {
        avatarTask?.cancel()
        avatarTask = nil
        representedID = nil
        authorID = nil
        avatarView.image = nil
    }

    @objc private func authorTapped() {
        guard let authorID else { return }
        onAuthorTapped?(authorID)
    }

    private static func countText(_ count: Int64) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : String(count)
    }
}

/// A view backed by a `CAGradientLayer`, sized automatically with its bounds.
final class GradientView: UIView {
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
