import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The author band a list row wears above its caption: the disc on the left at
/// two lines tall, the display name over the handle beside it, a follow control
/// trailing and centred on the pair.
///
/// ## Why it is a view and not a method on the cell
///
/// It is drawn TWICE, in two packages, and the two must be pixel-identical.
///
/// The row draws it. And a reveal draws it again — inside the destination, as a
/// transition prop, so that the window a viewer is holding shows the same
/// header the card does instead of a blank strip that the card's own header
/// then fades into. The whole point of that prop is that the swap at the
/// landing is the IDENTITY; two hand-written copies of one band would agree on
/// the day they were written and diverge from the first correction onward —
/// and they would diverge silently, because the only moment both are on screen
/// is the moment the transition is trying to make invisible.
///
/// So there is one band, configured from one model.
public final class PostAuthorBandView: UIView {
    /// The band's disc: two lines tall, because that is what it sits beside —
    /// the display name over the handle.
    public static let avatarDiameter: CGFloat = 40
    /// The gap between the band and the caption under it.
    public static let captionGap: CGFloat = 12
    /// How far below a card's top edge its caption begins, when the card wears
    /// one of these. The card's own top inset cancels — the band starts at
    /// `captionTopInset` and so does the caption inside a reveal's window — so
    /// what is left between them is the disc and the gap.
    public static let captionOffset: CGFloat = avatarDiameter + captionGap

    /// Everything the band draws, so a row and a transition prop are configured
    /// from one value rather than from two readings of a post.
    public struct Model: Equatable, Sendable {
        public let name: String
        public let handle: String
        public let avatarURL: URL?
        public let monogram: String

        /// `nil` when the post carries no identity at all — a profile
        /// gallery's posts do not, being already scoped to one author — and the
        /// band is then not drawn.
        public init?(post: GalleryPost) {
            let name = post.authorName?.trimmingCharacters(in: .whitespaces) ?? ""
            let handle = post.authorHandle?.trimmingCharacters(in: .whitespaces) ?? ""
            // Either half is enough to draw an identity, and neither is enough
            // to draw one without the other's absence showing — so the band is
            // shown for a post that has ANY of them and each label carries what
            // it has.
            guard !name.isEmpty || !handle.isEmpty else { return nil }
            self.name = name.isEmpty ? handle : name
            self.handle = handle
            avatarURL = post.authorAvatarURL
            monogram = Self.monogram(name: name, handle: handle)
        }

        /// Initials, on the app's rule: the display name when there is one, the
        /// handle when there is not.
        private static func monogram(name: String, handle: String) -> String {
            let source = name.isEmpty ? handle : name
            let initials = source
                .split(separator: " ")
                .prefix(2)
                .compactMap { $0.first.map { String($0).uppercased() } }
            return initials.isEmpty ? "?" : initials.joined()
        }
    }

    /// Fired when the viewer presses the follow control. `nil` on the reveal's
    /// prop, which is scenery and takes no touches.
    public var onFollowTapped: (() -> Void)?

    private let avatar = MonogramAvatarView(diameter: PostAuthorBandView.avatarDiameter)
    private let avatarImage = AvatarImageView()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let followButton = UIButton(type: .system)
    private var avatarTask: Task<Void, Never>?

    public init() {
        super.init(frame: .zero)

        nameLabel.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold
        )
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail

        handleLabel.font = .preferredFont(forTextStyle: .footnote)
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = .secondaryLabel
        handleLabel.lineBreakMode = .byTruncatingTail

        let identity = UIStackView(arrangedSubviews: [nameLabel, handleLabel])
        identity.axis = .vertical
        identity.alignment = .leading
        identity.spacing = 1

        followButton.titleLabel?.adjustsFontForContentSizeCategory = true
        // The identity yields first: a long display name should truncate before
        // a two-word control does, because the control's words are the ones a
        // reader has to be able to act on.
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        followButton.setContentHuggingPriority(.required, for: .horizontal)
        followButton.addTarget(self, action: #selector(followPressed), for: .touchUpInside)

        // The picture is laid OVER the monogram rather than replacing it — the
        // app's avatar contract: initials are the rendered state and a
        // photograph hydrates in front of them.
        avatarImage.pin(to: avatar)
        avatarImage.isHidden = true

        addSubview(avatar)
        addSubview(identity)
        addSubview(followButton)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        identity.translatesAutoresizingMaskIntoConstraints = false
        followButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
            avatar.topAnchor.constraint(equalTo: topAnchor),
            avatar.bottomAnchor.constraint(equalTo: bottomAnchor),

            identity.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: Spacing.sm),
            identity.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            identity.trailingAnchor.constraint(
                lessThanOrEqualTo: followButton.leadingAnchor, constant: -Spacing.sm
            ),

            followButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            // CENTRED on the disc, which is the pair's own height — the control
            // belongs to the identity beside it, not to the band's box.
            followButton.centerYAnchor.constraint(equalTo: avatar.centerYAnchor)
        ])
        setFollowing(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func followPressed() {
        onFollowTapped?()
    }

    public func configure(with model: Model, imagePipeline: ImagePipeline?) {
        avatarTask?.cancel()
        avatarTask = nil
        avatarImage.image = nil
        avatarImage.isHidden = true

        nameLabel.text = model.name
        handleLabel.text = model.handle.isEmpty ? nil : "@" + model.handle
        handleLabel.isHidden = model.handle.isEmpty
        avatar.setMonogram(model.monogram)

        guard let url = model.avatarURL, let imagePipeline else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            avatarImage.image = cached
            avatarImage.isHidden = false
            return
        }
        // Reuse is handled by CANCELLATION, as the row's cover load is: the
        // task is dropped in `prepareForReuse`, so a picture cannot arrive for
        // a post this band has stopped representing.
        avatarTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url),
                  !Task.isCancelled, let self
            else { return }
            self.avatarImage.image = image
            self.avatarImage.isHidden = false
        }
    }

    /// Drops any in-flight picture load. Called from the row's reuse.
    public func cancelPendingWork() {
        avatarTask?.cancel()
        avatarTask = nil
        avatarImage.image = nil
        avatarImage.isHidden = true
    }

    /// How the control reads. Two states, and the FOLLOWED one is the quiet
    /// side: an action already taken should not keep shouting for the tap that
    /// took it.
    public func setFollowing(_ following: Bool) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = following ? "Following" : "Follow"
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 4, leading: 10, bottom: 4, trailing: 10
        )
        configuration.baseForegroundColor = following ? .secondaryLabel : .tintColor
        configuration.background.backgroundColor = following
            ? .clear : UIColor.tintColor.withAlphaComponent(0.12)
        configuration.background.cornerRadius = 14
        followButton.configuration = configuration
        followButton.accessibilityLabel = following
            ? "Following this author" : "Follow this author"
    }
}
