import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The author band a list row wears above its caption: the disc on the left at
/// two lines tall, the display name over the handle beside it, an overflow
/// control trailing and centred on the pair.
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

    /// Fired when the viewer taps the identity — the disc, the name or the
    /// handle. `nil` on the reveal's prop, which is scenery and takes no
    /// touches.
    public var onAuthorTapped: (() -> Void)?

    /// The rows the "..." offers, asked for at the moment it is pressed.
    ///
    /// A PROVIDER rather than a stored menu, because what a row can offer
    /// depends on state the cell does not own and that can move under it — a
    /// follow that was just undone, a reporting seam that resolved late.
    ///
    /// ⚠️ It is asked TWICE, and the first time is the whole reason the control
    /// is ever hidden. Whether a provider EXISTS says nothing: a surface hands
    /// one to every row that has an author, and it is the ANSWER that turns out
    /// to be empty — the viewer's own post, which nobody may report and nobody
    /// may unfollow. Visibility that tracked the provider left a "..." that
    /// opened an empty sheet. So the rows are asked for once here, to decide
    /// whether the control is drawn at all, and again when it is pressed, for
    /// what it says.
    public var menuActions: (() -> [PostCardMenuAction])? {
        didSet { menuButton.isHidden = menuActions?().isEmpty ?? true }
    }

    private let avatar = MonogramAvatarView(diameter: PostAuthorBandView.avatarDiameter)
    private let avatarImage = AvatarImageView()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let menuButton = UIButton(type: .system)
    private let identityControl = UIControl()
    private var avatarTask: Task<Void, Never>?

    /// What a popover-shaped presentation should point at — the control the
    /// viewer actually pressed.
    public var menuAnchor: UIView { menuButton }

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
        // A CONTROL around the disc and the two labels, not a tap gesture on
        // them.
        //
        // The band lives inside a collection view cell whose whole face opens
        // the post. A `UITapGestureRecognizer` on a subview does not reliably
        // stop that — the collection view's selection is driven by its own
        // touch handling, and both would fire, opening the post *and* pushing
        // the profile. A `UIControl` consumes the touch, which is the same
        // reason an ordinary button inside a cell has never selected its row.
        identityControl.addTarget(self, action: #selector(authorPressed), for: .touchUpInside)
        // The contents are made INERT so the control itself is the hit view.
        //
        // Forwarding up the responder chain from a hit subview is not enough
        // here: the band sits inside a collection view, and a scroll view
        // decides whether to delay and whether to cancel a touch by asking what
        // the hit view IS — a control gets the touch immediately, anything else
        // is held and can be cancelled out from under it. This is the same
        // reason `UIButton` disables interaction on its own image and title.
        avatar.isUserInteractionEnabled = false
        identity.isUserInteractionEnabled = false
        nameLabel.isUserInteractionEnabled = false
        handleLabel.isUserInteractionEnabled = false

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "ellipsis")
        configuration.baseForegroundColor = .secondaryLabel
        // Zero insets and an explicit square below, rather than padding a glyph
        // out to size: the control is centred on the disc, so a tap target
        // grown by insets grows the band with it and pushes the caption down.
        configuration.contentInsets = .zero
        menuButton.configuration = configuration
        menuButton.accessibilityLabel = "More actions"
        // The menu IS the button's action — no touch-up handler, so there is no
        // frame in which the control is pressed and nothing has appeared.
        menuButton.showsMenuAsPrimaryAction = true
        // UNCACHED and deferred: the rows are asked for when the menu opens,
        // not when the cell is configured. A cached menu would offer to
        // unfollow someone the viewer unfollowed a moment ago from the same
        // row — the same reason the profile's "..." defers its own moderation
        // group.
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let actions = self?.menuActions?() else { return completion([]) }
                completion(actions.map(\.element))
            }
        ])
        menuButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        menuButton.setContentHuggingPriority(.required, for: .horizontal)

        // The picture is laid OVER the monogram rather than replacing it — the
        // app's avatar contract: initials are the rendered state and a
        // photograph hydrates in front of them.
        avatarImage.pin(to: avatar)
        avatarImage.isHidden = true

        identityControl.addSubview(avatar)
        identityControl.addSubview(identity)
        addSubview(identityControl)
        addSubview(menuButton)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        identity.translatesAutoresizingMaskIntoConstraints = false
        identityControl.translatesAutoresizingMaskIntoConstraints = false
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            identityControl.leadingAnchor.constraint(equalTo: leadingAnchor),
            identityControl.topAnchor.constraint(equalTo: topAnchor),
            identityControl.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The control ends where the IDENTITY ends, not where the band
            // does: the tappable region is the person, and the empty run
            // between a short name and the "..." belongs to the card.
            identityControl.trailingAnchor.constraint(
                lessThanOrEqualTo: menuButton.leadingAnchor, constant: -Spacing.sm
            ),

            avatar.leadingAnchor.constraint(equalTo: identityControl.leadingAnchor),
            avatar.topAnchor.constraint(equalTo: identityControl.topAnchor),
            avatar.bottomAnchor.constraint(equalTo: identityControl.bottomAnchor),

            identity.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: Spacing.sm),
            identity.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            identity.trailingAnchor.constraint(equalTo: identityControl.trailingAnchor),

            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            // CENTRED on the disc, which is the pair's own height — the control
            // belongs to the identity beside it, not to the band's box.
            menuButton.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            // A square the size of the disc: as much tap target as the band can
            // give without growing, and the glyph floats in the middle of it.
            menuButton.widthAnchor.constraint(equalToConstant: Self.avatarDiameter),
            menuButton.heightAnchor.constraint(equalToConstant: Self.avatarDiameter)
        ])
        menuButton.isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func authorPressed() {
        onAuthorTapped?()
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

    /// Draws the "..." without wiring it.
    ///
    /// For the reveal's PROPS — the destination's borrowed band and the
    /// dismissal's stand-in card. They are scenery: interaction is off, so
    /// nothing can be pressed, but they must show what the card shows or the
    /// control pops in at the landing, which is the one frame the whole
    /// transition exists to make invisible.
    public func showMenuControlAsScenery() {
        menuButton.isHidden = false
    }

    /// Drops any in-flight picture load. Called from the row's reuse.
    public func cancelPendingWork() {
        avatarTask?.cancel()
        avatarTask = nil
        avatarImage.image = nil
        avatarImage.isHidden = true
    }

}
