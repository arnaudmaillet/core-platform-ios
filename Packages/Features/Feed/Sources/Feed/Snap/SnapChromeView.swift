import CoreModels
import DesignSystem
import UIKit

/// The snap *page's* UI chrome — caption over the bottom scrim and the
/// engagement rail. Screen-scoped chrome (back item, author identity) lives in
/// the navigation bar instead (`SnapAuthorIdentityView` / `SnapNavControls`), so
/// it stays fixed while pages scroll.
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

    private let captionLabel = UILabel()

    private let likeButton = UIButton(configuration: .plain())
    private let likeCountLabel = UILabel()
    private let commentButton = UIButton(configuration: .plain())

    private let railStack: UIStackView

    /// Set by the owning cell; called on tap with the represented post.
    /// The flight replica leaves these nil and disables interaction entirely.
    var onLikeTapped: ((PostID) -> Void)?
    var onCommentTapped: ((PostID) -> Void)?

    /// Subtrees where a touch means "use the control", not "toggle playback" —
    /// consumed by the cell's tap arbitration.
    var interactionRoots: [UIView] { [railStack] }

    private var representedID: PostID?

    override init(frame: CGRect) {
        railStack = UIStackView(arrangedSubviews: [likeButton, likeCountLabel, commentButton])
        railStack.axis = .vertical
        railStack.spacing = Spacing.xs
        railStack.alignment = .center
        super.init(frame: frame)

        captionLabel.numberOfLines = 4
        captionLabel.textColor = .white
        // Legibility over arbitrary media, independent of the scrim.
        captionLabel.layer.shadowColor = UIColor.black.cgColor
        captionLabel.layer.shadowOpacity = 0.5
        captionLabel.layer.shadowRadius = 3
        captionLabel.layer.shadowOffset = .zero

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

        // Caption, bottom-left over the scrim; the trailing gap keeps it clear
        // of the engagement rail.
        captionLabel.constrain(in: self) { parent in
            captionLabel.leadingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.leadingAnchor, constant: Spacing.lg)
            captionLabel.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.lg)
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -72)
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

    func configure(with model: FeedItemDisplayModel, engagement: FeedViewModel.EngagementState) {
        representedID = model.id
        updateEngagement(engagement)

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

    /// Clears post-specific content (cell reuse).
    func reset() {
        representedID = nil
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
