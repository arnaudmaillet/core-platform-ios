import MediaCore
import DesignSystem
import UIKit

/// The profile identity block, layered over an immersive media banner:
/// `ProfileBannerView` runs from the very top of the screen (under the status
/// bar and transparent navigation bar) down to the bottom of the action tray,
/// and the identity content sits directly on top of it. The banner's bottom
/// fade dissolves into `systemBackground` under the identity rows, so they
/// keep standard dynamic label colors.
///
/// Identity anatomy:
/// - a tall banner-viewing window under the chrome (`Metrics.bannerClearance`
///   of raw media) — the relationship button lives in the navigation bar
///   (owned by `ProfileViewController`), NOT in this view;
/// - then the two-column identity block — circular avatar left, sized to span
///   the three lines beside it: display name + verified badge, @handle, and
///   the Liquid Glass action tray (Message capsule, then circular bookmark,
///   QR-code, and see-more bubbles, leading-aligned);
/// - below, full width: the 4-metric counter row (Followers / Following /
///   Reactions / Views) directly under the identity block, then bio and
///   website link closing the header right above the content threshold. The
///   banner ends at the TRAY's bottom (the identity block's baseline); the
///   counters and bio sit on plain background.
/// Pure presentation — it is handed a finished `ProfileDisplayModel` and an
/// `ImagePipeline`; it owns no data.
final class ProfileHeaderView: UIView {
    private enum Metrics {
        /// Dynamic-Type ceiling for the avatar (it normally tracks the
        /// identity column's height, ~95pt at default sizes).
        static let avatarMaxSize: CGFloat = 110
        static let avatarRingWidth: CGFloat = 3
        static let badgeSize: CGFloat = 18
        /// Raw-media window between the navigation chrome and the identity
        /// block — the banner's breathing room.
        static let bannerClearance: CGFloat = 160
        /// Side length of the circular glass bubbles in the action tray (and
        /// thus the height of the whole tray).
        static let bubbleSize: CGFloat = 44
        /// Content margins of the identity block — wider than the standard
        /// `Spacing.lg` page margin so the header reads airy against the
        /// full-bleed banner.
        static let horizontalInset: CGFloat = 20
    }

    private let bannerView: ProfileBannerView
    private let avatarView = CircleAvatarView()
    private let monogramLabel = UILabel()
    private let nameLabel = UILabel()
    private let verifiedBadge = UIImageView(image: UIImage(systemName: "checkmark.seal.fill"))
    private let handleLabel = UILabel()
    private let bioLabel = UILabel()
    private let websiteButton = UIButton(configuration: .plain())
    private let followersStat = ProfileStatView(caption: "Followers")
    private let followingStat = ProfileStatView(caption: "Following")
    private let reactionsStat = ProfileStatView(caption: "Reactions")
    private let viewsStat = ProfileStatView(caption: "Views")
    private let messageButton = UIButton(configuration: .glass())
    private let bookmarkButton = UIButton(configuration: .glass())
    private let qrCodeButton = UIButton(configuration: .glass())
    private let moreButton = UIButton(configuration: .glass())
    private var columnTopConstraint: NSLayoutConstraint?

    /// Pins the banner's top to the scroll viewport's top edge (required,
    /// as an inequality), so that when the user overscrolls downward the
    /// banner's soft attachment to the header top gives way and the media
    /// stretches to keep covering the screen from y = 0 — no background gap.
    /// When content scrolls up, the inequality is slack and the banner leaves
    /// the screen with the header as usual. Called once by the owning
    /// controller with its scroll view's `frameLayoutGuide.topAnchor`; the
    /// header stays scroll-view-agnostic.
    func anchorBanner(toViewportTop viewportTop: NSLayoutYAxisAnchor) {
        bannerView.topAnchor.constraint(lessThanOrEqualTo: viewportTop).isActive = true
    }

    /// Height of the status-bar + navigation chrome the banner runs under,
    /// supplied by the owning controller (the header can't know it: its own
    /// safe area shifts as the scroll view moves). The identity column starts
    /// a full banner-clearance below this inset; the banner ignores it and
    /// bleeds to y = 0.
    var chromeTopInset: CGFloat = 0 {
        didSet { columnTopConstraint?.constant = chromeTopInset + Metrics.bannerClearance }
    }

    /// Invoked when the Message button is tapped (other users only).
    var onMessageTapped: (() -> Void)?
    /// Invoked when the bookmark bubble is tapped.
    var onBookmarkTapped: (() -> Void)?
    /// Invoked when the QR-code bubble is tapped.
    var onQRCodeTapped: (() -> Void)?
    /// Invoked when the see-more (ellipsis) bubble is tapped.
    var onMoreTapped: (() -> Void)?
    /// Invoked with the profile's website URL when the link row is tapped.
    var onWebsiteTapped: ((URL) -> Void)?

    private let imagePipeline: ImagePipeline
    private var avatarTask: Task<Void, Never>?
    private var currentAvatarURL: URL?
    private var websiteURL: URL?

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        bannerView = ProfileBannerView(imagePipeline: imagePipeline)
        super.init(frame: .zero)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        avatarTask?.cancel()
    }

    // MARK: - Configuration

    func configure(with model: ProfileDisplayModel) {
        monogramLabel.text = model.avatarMonogram
        nameLabel.text = model.displayName
        handleLabel.text = model.handle
        verifiedBadge.isHidden = !model.isVerified

        bioLabel.text = model.bio
        bioLabel.isHidden = !model.hasBio

        websiteURL = model.websiteURL
        websiteButton.configuration?.title = model.websiteText
        websiteButton.isHidden = model.websiteText == nil

        followersStat.setValue(model.followerText)
        followingStat.setValue(model.followingText)
        reactionsStat.setValue(model.reactionsText)
        viewsStat.setValue(model.viewsText)

        bannerView.setImageURL(model.bannerImageURL)
        loadAvatar(model.avatarURL)
    }

    /// Adjusts the tray to the viewer's relationship: Message applies to other
    /// users only; the QR and see-more bubbles are always available. The
    /// Follow / Following / Edit button itself lives in the navigation bar and
    /// is styled by `ProfileViewController`.
    func configureAction(_ state: ProfileViewModel.FollowButton) {
        switch state {
        case .follow, .following:
            messageButton.isHidden = false
        case .hidden, .edit:
            messageButton.isHidden = true
        }
    }

    // MARK: - Redaction

    private var isRedacted = false
    private var redactionBones: [SkeletonBoneView] = []

    /// Structural skeleton state: the redacted header IS the real header. The
    /// same views, constraints, and fonts carry the layout — each awaiting
    /// label holds a blank line of placeholder text so its metric height (and
    /// everything derived from it: the identity column, the avatar span, the
    /// banner's bottom threshold) resolves exactly where content will land —
    /// while shimmer bones anchored to those very elements mask the missing
    /// values. The glass tray and stat captions are chrome, not content, and
    /// stay real. Reveal (`redacted: false`, called after `configure(with:)`
    /// has swapped real text in under the invisible labels) trades only
    /// alphas, so hydration cannot shift a single pixel of structure.
    func setRedacted(_ redacted: Bool, animated: Bool = false) {
        guard redacted != isRedacted else { return }
        isRedacted = redacted

        if redacted {
            // Layout ballast: one blank line per single-line label, two for
            // the bio's typical measure. The website row is reserved too —
            // hiding it here and inserting it at reveal would push the whole
            // gallery down mid-fade (most profiles carry a link; a linkless
            // one collapses the row as a content change, not a reveal jump).
            nameLabel.text = " "
            handleLabel.text = " "
            bioLabel.text = " \n "
            bioLabel.isHidden = false
            websiteButton.configuration?.title = " "
            websiteButton.isHidden = false
            installRedactionBones()
            // Everything data-driven drops to alpha 0 in place — the badge
            // included, so a verified profile fades it in with the name
            // instead of popping it beside the finished text.
            for view in [nameLabel, handleLabel, bioLabel, websiteButton, verifiedBadge] {
                view.alpha = 0
            }
            for bone in redactionBones { bone.isHidden = false; bone.alpha = 1 }
            for stat in [followersStat, followingStat, reactionsStat, viewsStat] {
                stat.setRedacted(true)
            }
            bannerView.setRedacted(true)
            return
        }

        // Alpha-only choreography: `configure(with:)` has already committed
        // the real content (and any structural truth like a hidden website
        // row) OUTSIDE this animation, so nothing here can move — the bones
        // dissolve and the content materializes exactly where they were.
        let reveal = {
            for view in [
                self.nameLabel, self.handleLabel, self.bioLabel,
                self.websiteButton, self.verifiedBadge
            ] {
                view.alpha = 1
            }
            for bone in self.redactionBones { bone.alpha = 0 }
            for stat in [self.followersStat, self.followingStat, self.reactionsStat, self.viewsStat] {
                stat.setRedacted(false)
            }
            self.bannerView.setRedacted(false)
        }
        let finish = {
            for bone in self.redactionBones { bone.isHidden = true }
        }
        guard animated else {
            reveal()
            finish()
            return
        }
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut]) {
            reveal()
        } completion: { _ in
            // Re-entered redaction mid-fade keeps its bones up.
            guard !self.isRedacted else { return }
            finish()
        }
    }

    /// One-time overlay construction, anchored to the real elements so the
    /// bones inherit their exact resolved positions.
    private func installRedactionBones() {
        guard redactionBones.isEmpty else { return }

        // The avatar's own clipping rounds the bone; the ring border draws
        // above it, staying crisp.
        let avatarBone = SkeletonBoneView(rounding: .fixed(0))
        avatarBone.pin(to: avatarView)

        let nameBone = SkeletonBoneView()
        nameBone.constrain(in: self) { _ in
            nameBone.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor)
            nameBone.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor)
            nameBone.widthAnchor.constraint(equalToConstant: 148)
            nameBone.heightAnchor.constraint(equalToConstant: 16)
        }

        let handleBone = SkeletonBoneView()
        handleBone.constrain(in: self) { _ in
            handleBone.leadingAnchor.constraint(equalTo: handleLabel.leadingAnchor)
            handleBone.centerYAnchor.constraint(equalTo: handleLabel.centerYAnchor)
            handleBone.widthAnchor.constraint(equalToConstant: 92)
            handleBone.heightAnchor.constraint(equalToConstant: 12)
        }

        // Two caption-pitch bars inside the bio's two placeholder lines.
        let bioFirst = SkeletonBoneView()
        bioFirst.constrain(in: self) { _ in
            bioFirst.leadingAnchor.constraint(equalTo: bioLabel.leadingAnchor)
            bioFirst.trailingAnchor.constraint(equalTo: bioLabel.trailingAnchor)
            bioFirst.topAnchor.constraint(equalTo: bioLabel.topAnchor, constant: 4)
            bioFirst.heightAnchor.constraint(equalToConstant: 12)
        }
        let bioSecond = SkeletonBoneView()
        bioSecond.constrain(in: self) { _ in
            bioSecond.leadingAnchor.constraint(equalTo: bioLabel.leadingAnchor)
            bioSecond.widthAnchor.constraint(equalTo: bioLabel.widthAnchor, multiplier: 0.55)
            bioSecond.bottomAnchor.constraint(equalTo: bioLabel.bottomAnchor, constant: -4)
            bioSecond.heightAnchor.constraint(equalToConstant: 12)
        }

        let websiteBone = SkeletonBoneView()
        websiteBone.constrain(in: self) { _ in
            websiteBone.leadingAnchor.constraint(equalTo: websiteButton.leadingAnchor)
            websiteBone.centerYAnchor.constraint(equalTo: websiteButton.centerYAnchor)
            websiteBone.widthAnchor.constraint(equalToConstant: 120)
            websiteBone.heightAnchor.constraint(equalToConstant: 12)
        }

        redactionBones = [avatarBone, nameBone, handleBone, bioFirst, bioSecond, websiteBone]
    }

    /// Shared chrome for the tray's glass text capsules: Liquid Glass pill
    /// with a semibold compact title.
    private static func styledCapsule(_ base: UIButton.Configuration) -> UIButton.Configuration {
        var config = base
        config.cornerStyle = .capsule
        // md, not lg, side insets: the capsule shares the avatar-side column
        // with three bubbles; the tighter title keeps the tray within budget.
        config.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md
        )
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return attributes
        }
        return config
    }

    /// A circular Liquid Glass bubble holding a single SF Symbol.
    private static func glassBubble(systemImage: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.glass()
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: systemImage)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        config.contentInsets = .zero
        return config
    }

    private func loadAvatar(_ url: URL?) {
        guard url != currentAvatarURL || avatarView.image == nil else { return }
        currentAvatarURL = url
        avatarTask?.cancel()
        avatarView.image = nil // fall back to the monogram until (and unless) the image resolves

        guard let url else { return }
        let pipeline = imagePipeline
        avatarTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, !Task.isCancelled, self.currentAvatarURL == url else { return }
            // Async arrival dissolves over the monogram instead of popping.
            UIView.transition(
                with: self.avatarView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.avatarView.image = image
            }
        }
    }

    // MARK: - Layout

    private func configureSubviews() {
        // Avatar: a filled circle with a monogram, overlaid by the image once
        // loaded. The ring keeps it defined while it floats over raw banner
        // media, above the fade.
        avatarView.backgroundColor = .tertiarySystemFill
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.borderWidth = Metrics.avatarRingWidth
        avatarView.layer.borderColor = UIColor.systemBackground.cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ProfileHeaderView, _) in
            self.avatarView.layer.borderColor = UIColor.systemBackground.cgColor
        }

        monogramLabel.font = .systemFont(ofSize: 34, weight: .semibold)
        monogramLabel.textColor = .secondaryLabel
        monogramLabel.textAlignment = .center
        monogramLabel.pin(to: avatarView)
        // The avatar's side length is resolved by layout (it tracks the
        // identity column), so the monogram scales off the resolved frame —
        // reported by the avatar itself, whose layout pass is the first to
        // see the final size (the header's runs too early for nested stacks).
        avatarView.onSideLengthChange = { [weak self] side in
            guard let self, side > 0 else { return }
            let monogramSize = (side * 0.4).rounded()
            if abs(self.monogramLabel.font.pointSize - monogramSize) > 0.5 {
                self.monogramLabel.font = .systemFont(ofSize: monogramSize, weight: .semibold)
            }
        }

        // The 4-metric counter row, last element of the header: equal cells
        // across the full content width, right above the content threshold.
        let statsRow = UIStackView(arrangedSubviews: [followersStat, followingStat, reactionsStat, viewsStat])
        statsRow.axis = .horizontal
        statsRow.alignment = .center
        statsRow.distribution = .fillEqually

        // Type hierarchy of the identity block, three clear steps: title3
        // semibold display name (the block's anchor; SF applies its tighter
        // large-size tracking automatically), subheadline secondary @handle,
        // subheadline bio below — name > handle = body copy, one weight jump.
        nameLabel.font = UIFont.preferredFont(forTextStyle: .title3).withWeight(.semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1

        handleLabel.font = .preferredFont(forTextStyle: .subheadline)
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = .secondaryLabel
        handleLabel.numberOfLines = 1

        verifiedBadge.tintColor = .systemBlue
        verifiedBadge.contentMode = .scaleAspectFit
        verifiedBadge.setContentHuggingPriority(.required, for: .horizontal)

        bioLabel.font = .preferredFont(forTextStyle: .subheadline)
        bioLabel.adjustsFontForContentSizeCategory = true
        bioLabel.textColor = .label
        bioLabel.numberOfLines = 0

        // Name + verified badge sit on one line; a spacer keeps them leading
        // while the row itself stretches with the fill-aligned column.
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, verifiedBadge, UIView()])
        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = Spacing.xs
        NSLayoutConstraint.activate([
            verifiedBadge.widthAnchor.constraint(equalToConstant: Metrics.badgeSize),
            verifiedBadge.heightAnchor.constraint(equalToConstant: Metrics.badgeSize)
        ])

        var messageConfig = Self.styledCapsule(.glass())
        messageConfig.title = "Message"
        messageButton.configuration = messageConfig
        messageButton.isHidden = true
        messageButton.addAction(
            UIAction { [weak self] _ in self?.onMessageTapped?() },
            for: .primaryActionTriggered
        )

        bookmarkButton.configuration = Self.glassBubble(systemImage: "bookmark")
        bookmarkButton.addAction(
            UIAction { [weak self] _ in self?.onBookmarkTapped?() },
            for: .primaryActionTriggered
        )
        qrCodeButton.configuration = Self.glassBubble(systemImage: "qrcode")
        qrCodeButton.addAction(
            UIAction { [weak self] _ in self?.onQRCodeTapped?() },
            for: .primaryActionTriggered
        )
        moreButton.configuration = Self.glassBubble(systemImage: "ellipsis")
        moreButton.addAction(
            UIAction { [weak self] _ in self?.onMoreTapped?() },
            for: .primaryActionTriggered
        )

        // The Liquid Glass tray, split composition: Message + bookmark lead
        // the identity stack; a stretching mid-spacer forces the QR and
        // see-more bubbles flush against the identity block's trailing edge.
        // The spacer's neighbors get zero stack spacing — the spacer IS the
        // gap — so the tray degrades gracefully when width is scarce. The
        // split holds whether or not Message is visible (own profile).
        let traySpacer = UIView()
        traySpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let actionRow = UIStackView(
            arrangedSubviews: [messageButton, bookmarkButton, traySpacer, qrCodeButton, moreButton]
        )
        actionRow.axis = .horizontal
        actionRow.alignment = .fill
        actionRow.distribution = .fill
        actionRow.spacing = Spacing.sm
        actionRow.setCustomSpacing(0, after: bookmarkButton)
        actionRow.setCustomSpacing(0, after: traySpacer)
        for bubble in [bookmarkButton, qrCodeButton, moreButton] {
            // The diameter is 999, not required: on the narrowest devices the
            // tray can overrun the column beside the avatar, and the bubbles
            // shaving a point (staying circular via the required square tie)
            // beats an unsatisfiable-constraints break.
            let diameter = bubble.widthAnchor.constraint(equalToConstant: Metrics.bubbleSize)
            diameter.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                diameter,
                bubble.heightAnchor.constraint(equalTo: bubble.widthAnchor)
            ])
        }

        // Right column of the top block: name, @handle, then the glass tray —
        // three lines the avatar spans.
        let identityColumn = UIStackView(arrangedSubviews: [nameRow, handleLabel, actionRow])
        identityColumn.axis = .vertical
        identityColumn.alignment = .fill
        identityColumn.spacing = Spacing.xs
        identityColumn.setCustomSpacing(Spacing.md, after: handleLabel)

        let topRow = UIStackView(arrangedSubviews: [avatarView, identityColumn])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = Spacing.md

        var websiteConfig = UIButton.Configuration.plain()
        websiteConfig.image = UIImage(systemName: "link")
        websiteConfig.imagePadding = Spacing.xs
        websiteConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        websiteConfig.baseForegroundColor = .systemBlue
        websiteConfig.contentInsets = .zero
        websiteConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return attributes
        }
        websiteButton.configuration = websiteConfig
        websiteButton.contentHorizontalAlignment = .leading
        websiteButton.isHidden = true
        websiteButton.addAction(
            UIAction { [weak self] _ in
                guard let self, let websiteURL = self.websiteURL else { return }
                self.onWebsiteTapped?(websiteURL)
            },
            for: .primaryActionTriggered
        )

        // Page column: the two-column identity block (avatar | name/@handle/
        // tray), then full width — the counter row directly under the identity
        // block, then bio and website closing the header right above the
        // content threshold. Wider vertical rhythm than the standard xs-step
        // stacks: the header sits against a full-bleed banner and needs air
        // between its major containers to read premium.
        let column = UIStackView(arrangedSubviews: [topRow, statsRow, bioLabel, websiteButton])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Spacing.sm
        column.setCustomSpacing(Spacing.lg, after: topRow)
        column.setCustomSpacing(Spacing.md, after: statsRow)

        // Layering: banner first (back), identity column on top of it. The
        // banner bleeds to the header's very top — the column starts below the
        // navigation chrome via `chromeTopInset` — and its bottom edge is tied
        // to the action tray's, so it always ends exactly at the tray's bottom
        // threshold no matter which identity rows are visible.
        //
        // The top attachment is deliberately soft (high, not required): the
        // owning controller adds a required ≤-viewport-top constraint via
        // `anchorBanner(toViewportTop:)`, and downward overscroll must be able
        // to break this equality so the banner stretches instead of sliding
        // down with the content and exposing the scroll view's background.
        let bannerTop = bannerView.topAnchor.constraint(equalTo: topAnchor)
        bannerTop.priority = .defaultHigh
        bannerView.constrain(in: self) { parent in
            bannerTop
            bannerView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            bannerView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        }

        let columnTop = column.topAnchor.constraint(
            equalTo: topAnchor, constant: chromeTopInset + Metrics.bannerClearance
        )
        columnTopConstraint = columnTop
        column.constrain(in: self) { parent in
            columnTop
            column.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Metrics.horizontalInset)
            column.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Metrics.horizontalInset)
            column.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Spacing.xl)
        }

        // The avatar spans the identity column's three lines: a square tied to
        // the column's height (the column sits at its natural height; the
        // avatar has no intrinsic size — see CircleAvatarView — so it follows).
        // The tie sits just under the required Dynamic-Type cap: past the cap
        // the avatar stops growing and re-centers against the column.
        let avatarSpan = avatarView.heightAnchor.constraint(equalTo: identityColumn.heightAnchor)
        avatarSpan.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            bannerView.bottomAnchor.constraint(equalTo: actionRow.bottomAnchor),
            avatarView.widthAnchor.constraint(equalTo: avatarView.heightAnchor),
            avatarSpan,
            avatarView.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.avatarMaxSize)
        ])
    }

}

/// An image view that stays a circle whatever side length layout resolves for
/// it. The rounding must live here — in the bounds' owner — because ancestor
/// `layoutSubviews` runs before nested stack views hand this view its final
/// frame, and would round a stale size.
private final class CircleAvatarView: UIImageView {
    var onSideLengthChange: ((CGFloat) -> Void)?

    /// The avatar is sized purely by constraints. A loaded bitmap must not
    /// vote: even at floor priorities an image view's intrinsic size is an
    /// unopposed preference that distorts any non-required sizing around it
    /// (it once dragged a span equality to its cap, stretching the identity
    /// rows apart).
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        onSideLengthChange?(bounds.height)
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        .systemFont(ofSize: pointSize, weight: weight)
    }
}
