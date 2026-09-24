import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The band a list row wears above its caption, in one of two shapes:
///
/// ```
///   identity                                   bare
///   ┌───────────────────────────────────┐      ┌───────────────────────────┐
///   │ (◯) Name                      ••• │      │ 2h                    ••• │
///   │     @handle · 2h                  │      └───────────────────────────┘
///   └───────────────────────────────────┘
/// ```
///
/// **Identity** is the disc, the display name over the handle, and the date
/// on the handle's line — one line that says who and when, so the row below
/// the caption is free for what the viewer can DO. **Bare** is what a card
/// wears where the identity would only repeat the screen: a profile's own
/// posts, already under that person's name. The date and the overflow are
/// what remain, on a line the height of a pill, because a date alone does
/// not need a disc's worth of card.
///
/// The trailing end is the "..." alone. Repost and save used to sit beside it
/// in a capsule, which gave every card two clusters of controls — one at the
/// top competing with the name, one at the bottom with the counts. They are
/// in the row's closing line now, with the counts, where every control on a
/// card lives.
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
    /// The height of a BARE band — the "..." control's own, which is the one
    /// height every pill on the card is.
    public static var bareHeight: CGFloat { PostMetaPillView.height }
    /// The width of the "..." control.
    public static var actionControlWidth: CGFloat { PostActionPillView.controlWidth }
    /// How far below a card's top edge its caption begins, when the card wears
    /// a band of the given shape. The card's own top inset cancels — the band
    /// starts at `captionTopInset` and so does the caption inside a reveal's
    /// window — so what is left between them is the band and the gap.
    public static func captionOffset(showsIdentity: Bool) -> CGFloat {
        (showsIdentity ? avatarDiameter : bareHeight) + captionGap
    }
    /// The band's own height for a shape.
    public static func height(showsIdentity: Bool) -> CGFloat {
        showsIdentity ? avatarDiameter : bareHeight
    }

    /// Everything the band draws, so a row and a transition prop are configured
    /// from one value rather than from two readings of a post.
    public struct Model: Equatable, Sendable {
        /// The display name, or nil for a BARE band that names nobody.
        public let name: String?
        public let handle: String
        public let avatarURL: URL?
        public let monogram: String
        /// The post's compact age, as the band shows it. Carried on the model
        /// rather than derived at draw time: a compact age is a function of
        /// the clock, and the row and the prop that copies it must agree.
        public let age: String

        /// Whether the band draws a person at all.
        public var showsIdentity: Bool { name != nil }

        /// - Parameter showsIdentity: false for a surface where the author is
        ///   the screen itself. A post that carries no author at all is bare
        ///   whatever the caller asks — there is nobody to draw.
        /// - Parameter age: the age to show, or nil to work it out from the
        ///   post now.
        public init(post: GalleryPost, showsIdentity: Bool = true, age: String? = nil) {
            let name = post.authorName?.trimmingCharacters(in: .whitespaces) ?? ""
            let handle = post.authorHandle?.trimmingCharacters(in: .whitespaces) ?? ""
            self.age = age ?? PostMetadata.compactAge(ofMillis: post.publishedAtMS)
            // Either half is enough to draw an identity, and neither is enough
            // to draw one without the other's absence showing — so the band
            // shows a person for a post that has ANY of them and each label
            // carries what it has.
            guard showsIdentity, !name.isEmpty || !handle.isEmpty else {
                self.name = nil
                self.handle = ""
                avatarURL = nil
                monogram = ""
                return
            }
            self.name = name.isEmpty ? handle : name
            self.handle = handle
            avatarURL = post.authorAvatarURL
            monogram = Self.monogram(name: name, handle: handle)
        }

        /// The same band with a different date — what a stand-in does to show
        /// the row's own reading rather than this instant's.
        public func withAge(_ age: String) -> Model {
            Model(name: name, handle: handle, avatarURL: avatarURL, monogram: monogram, age: age)
        }

        private init(name: String?, handle: String, avatarURL: URL?, monogram: String, age: String) {
            self.name = name
            self.handle = handle
            self.avatarURL = avatarURL
            self.monogram = monogram
            self.age = age
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

    /// What the band is currently drawing.
    public private(set) var model: Model?

    private let avatar = MonogramAvatarView(diameter: PostAuthorBandView.avatarDiameter)
    private let avatarImage = AvatarImageView()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    /// The bare band's date, alone on the leading side.
    private let bareAgeLabel = UILabel()
    private let menuButton = PostActionPillView.makeGlyphControl(systemName: "ellipsis", label: "More actions")
    private let identityControl = UIControl()
    /// The identity's vertical claim on the band — released for a bare band,
    /// whose height is the control's rather than the disc's.
    private var identityHeightConstraints: [NSLayoutConstraint] = []
    private var bareHeightConstraint: NSLayoutConstraint!
    private var avatarTask: Task<Void, Never>?

    /// What a popover-shaped presentation should point at — the control the
    /// viewer actually pressed.
    public var menuAnchor: UIView { menuButton }

    public init() {
        super.init(frame: .zero)

        // The name at the CAPTION's size, semibold; the handle and the date a
        // step below it, secondary. Three registers on a card — who, in bold;
        // when and where, quiet; what they said, in the caption's plain body
        // — and the name is the one that used to be smaller than the words
        // under it, which flattened the card into one grey block of type.
        nameLabel.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold
        )
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail

        for label in [handleLabel, bareAgeLabel] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.lineBreakMode = .byTruncatingTail
        }

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
        bareAgeLabel.isUserInteractionEnabled = false

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
        // ⚠️ THE "..." OUTRANKS THE IDENTITY HORIZONTALLY.
        //
        // A name and a handle are the compressible half of this band: they
        // already truncate by tail, and a long one must give way rather than
        // push the control off the card. Required resistance on the control
        // plus low resistance on the labels is what decides that — without
        // both, the labels' default 750 wins some layouts and the button is
        // clipped.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        handleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bareAgeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The picture is laid OVER the monogram rather than replacing it — the
        // app's avatar contract: initials are the rendered state and a
        // photograph hydrates in front of them.
        avatarImage.pin(to: avatar)
        avatarImage.isHidden = true

        identityControl.addSubview(avatar)
        identityControl.addSubview(identity)
        addSubview(identityControl)
        addSubview(bareAgeLabel)
        addSubview(menuButton)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        identity.translatesAutoresizingMaskIntoConstraints = false
        identityControl.translatesAutoresizingMaskIntoConstraints = false
        bareAgeLabel.translatesAutoresizingMaskIntoConstraints = false
        identityHeightConstraints = [
            identityControl.topAnchor.constraint(equalTo: topAnchor),
            identityControl.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        bareHeightConstraint = heightAnchor.constraint(equalToConstant: Self.bareHeight)
        NSLayoutConstraint.activate([
            identityControl.leadingAnchor.constraint(equalTo: leadingAnchor),
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

            // The bare date sits on the caption's own column: the line is
            // read with the words under it, not with the capsules two lines
            // further down, and a padding borrowed from a capsule reads as
            // an indent beside a bare "...".
            bareAgeLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            bareAgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            bareAgeLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: menuButton.leadingAnchor, constant: -Spacing.sm
            ),

            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            // ⚠️ TOP-ALIGNED, and it is the CARD's corner that decides that.
            //
            // Centred on the disc, the control sat below the card's top-right
            // arc. Hung from the band's top edge it lands inset from that
            // corner by exactly what the band is inset by. As tall as a pill,
            // which on a bare band is the band itself.
            menuButton.topAnchor.constraint(equalTo: topAnchor),
            menuButton.heightAnchor.constraint(equalToConstant: PostMetaPillView.height)
        ])
        NSLayoutConstraint.activate(identityHeightConstraints)
        menuButton.isHidden = true
        bareAgeLabel.isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func authorPressed() {
        onAuthorTapped?()
    }

    public func configure(with model: Model, imagePipeline: ImagePipeline?) {
        self.model = model
        avatarTask?.cancel()
        avatarTask = nil
        avatarImage.image = nil
        avatarImage.isHidden = true

        let showsIdentity = model.showsIdentity
        identityControl.isHidden = !showsIdentity
        bareAgeLabel.isHidden = showsIdentity
        bareAgeLabel.text = model.age
        if showsIdentity {
            bareHeightConstraint.isActive = false
            NSLayoutConstraint.activate(identityHeightConstraints)
        } else {
            NSLayoutConstraint.deactivate(identityHeightConstraints)
            bareHeightConstraint.isActive = true
        }

        nameLabel.text = model.name
        // "@handle · 2h": who and when on one quiet line. A post with no
        // handle keeps the date alone there rather than an orphaned dot.
        handleLabel.text = [model.handle.isEmpty ? nil : "@" + model.handle, model.age]
            .compactMap { $0 }
            .joined(separator: " · ")
        avatar.setMonogram(model.monogram)

        guard showsIdentity, let url = model.avatarURL, let imagePipeline else { return }
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
