import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// A person row in the followers / following list: identity disc, display name
/// over @handle, and the viewer's decision on the trailing edge.
///
/// A stock `UICollectionViewListCell` with a system content configuration and
/// two custom *accessories*, rather than a hand-laid content view. That is what
/// keeps it vanilla — the list cell retains ownership of its separators (inset
/// past the leading accessory automatically), its selection and highlight
/// states, its swipe actions and its Dynamic Type metrics, none of which a
/// bespoke content view inherits. It is the same anatomy the compose picker's
/// `PersonListCell` uses, with the action button added on the trailing side.
final class RelationshipListCell: UICollectionViewListCell {
    /// UIKit *asserts* that a custom accessory view keeps
    /// `translatesAutoresizingMaskIntoConstraints` enabled, while both the
    /// identity disc and the action button size themselves with constraints on
    /// themselves — so each travels inside a frame-sized host that uses Auto
    /// Layout internally, which is exactly the arrangement the assertion allows.
    private final class AvatarAccessoryView: UIView {
        override var intrinsicContentSize: CGSize {
            CGSize(width: MonogramAvatarView.rowDiameter, height: MonogramAvatarView.rowDiameter)
        }
    }

    /// Host for the trailing button, as wide as the **longest title the
    /// column can ever show**, the button inside it pinned to its trailing
    /// edge at its own title's width.
    ///
    /// The host's constant width keeps every row's accessory the same, so
    /// the accessory never has to be resized after it is installed (it
    /// reserves `.actual` width once). The button inside resizes freely —
    /// on a spring, through `MorphingButton` (#726) — and every pill keeps
    /// one right edge.
    ///
    /// ⚠️ THE LONGEST OF ALL THE TITLES (#726). The width used to be measured
    /// from "Following" alone; "Follow Back" (#717) is longer, and wrapped onto
    /// two lines inside a host one word too narrow.
    private final class ActionAccessoryView: UIView {
        let button = MorphingButton(frame: .zero)

        override var intrinsicContentSize: CGSize {
            CGSize(width: Self.reservedWidth(for: traitCollection), height: UIView.noIntrinsicMetric)
        }

        init() {
            super.init(frame: .zero)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor),
                button.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        /// Measured from real configured buttons — the capsule's content
        /// insets aren't knowable by arithmetic — and memoized per content-size
        /// category, so it costs one probe per title per Dynamic Type setting
        /// rather than per row.
        private static var cached: (category: UIContentSizeCategory, width: CGFloat)?

        private static func reservedWidth(for traits: UITraitCollection) -> CGFloat {
            let category = traits.preferredContentSizeCategory
            if let cached, cached.category == category { return cached.width }
            let actions: [ProfileRelationshipsViewModel.RowAction] = [.follow, .followBack, .following, .requested]
            // ⚠️ TYPED BY HAND: Xcode 26 (CI) inferred the closure's result as
            // Double and would not convert it into the cache's CGFloat tuple.
            let widths: [CGFloat] = actions.compactMap(RelationshipListCell.buttonConfiguration(for:)).map { configuration in
                let probe = UIButton(type: .system)
                probe.configuration = configuration
                let fitted: CGFloat = probe.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
                return fitted.rounded(.up)
            }
            let width: CGFloat = widths.max() ?? 0
            cached = (category: category, width: width)
            return width
        }

        /// The widest title's width. Internal for tests.
        static func debugReservedWidth(for traits: UITraitCollection) -> CGFloat { reservedWidth(for: traits) }
    }

    /// Built once per cell and handed back on every configure — accessories
    /// replace their custom view wholesale, and allocating fresh ones per reuse
    /// would churn two views for every scrolled row.
    private let avatarHost = AvatarAccessoryView(
        frame: CGRect(x: 0, y: 0, width: MonogramAvatarView.rowDiameter, height: MonogramAvatarView.rowDiameter)
    )
    private let monogramView = MonogramAvatarView()
    private let avatarView = AvatarImageView()
    private let actionHost = ActionAccessoryView()
    /// Who the row shows and the action it offers them: a change for the same
    /// person morphs the button, a new person does not.
    private var shownProfileID: ProfileID?
    private var shownAction: ProfileRelationshipsViewModel.RowAction?

    /// The trailing button. Internal for tests.
    var debugActionButton: MorphingButton { actionHost.button }
    /// The width every row reserves for its button. Internal for tests.
    var debugReservedActionWidth: CGFloat { ActionAccessoryView.debugReservedWidth(for: traitCollection) }

    /// Invoked when the trailing button is tapped. Reset on reuse so a recycled
    /// cell can never act on the person it used to show.
    var onAction: (() -> Void)?

    private var imagePipeline: ImagePipeline?
    private var currentAvatarURL: URL?
    private var avatarTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        monogramView.pin(to: avatarHost)
        // The image overlays the disc exactly, leaving the monogram behind it
        // as the permanent fallback — a row never renders as an empty circle.
        avatarView.pin(to: monogramView)
        actionHost.button.addAction(
            UIAction { [weak self] _ in self?.onAction?() },
            for: .primaryActionTriggered
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
        avatarTask?.cancel()
        avatarTask = nil
        currentAvatarURL = nil
        avatarView.image = nil
    }

    func configure(with row: ProfileRelationshipsViewModel.Row, imagePipeline: ImagePipeline?) {
        self.imagePipeline = imagePipeline
        monogramView.setMonogram(row.monogram)

        var content = UIListContentConfiguration.subtitleCell()
        content.attributedText = Self.nameText(for: row)
        content.secondaryText = row.handle
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .appFont(forTextStyle: .subheadline)
        // The same row height every other people list in the app uses, worked
        // back from the shared target rather than copied from another cell's
        // margin — see `PersonRowMetrics`.
        var margins = content.directionalLayoutMargins
        let margin = PersonRowMetrics.verticalInset(
            forContentHeight: PersonRowMetrics.textHeight([.headline, .subheadline]), minimum: 0
        )
        margins.top = margin
        margins.bottom = margin
        content.directionalLayoutMargins = margins
        contentConfiguration = content

        var accessories: [UICellAccessory] = [
            .customView(configuration: .init(
                customView: avatarHost,
                placement: .leading(displayed: .always),
                reservedLayoutWidth: .actual,
                maintainsFixedSize: true
            ))
        ]
        if let action = Self.buttonConfiguration(for: row.action) {
            // The same person changing state morphs (#726); a new person —
            // a reused cell — takes theirs at once.
            let changes = shownProfileID == row.id && shownAction != nil && shownAction != row.action
            actionHost.button.morph(to: action, animated: changes)
            actionHost.button.accessibilityLabel = Self.actionLabel(for: row)
            accessories.append(.customView(configuration: .init(
                customView: actionHost,
                placement: .trailing(displayed: .always),
                reservedLayoutWidth: .actual
            )))
        }
        self.accessories = accessories
        shownProfileID = row.id
        shownAction = row.action

        // VoiceOver hears the badge too — it is the whole point of the badge,
        // and it must not be a sighted-only cue.
        accessibilityLabel = [row.isViewer ? "\(row.displayName), Me" : row.displayName, row.handle]
            .joined(separator: ", ")
    }

    /// The row's decision, styled to the app's existing follow affordance (the
    /// inbox's suggestion rows): a small capsule, filled while it is an
    /// invitation (Follow, Follow Back) and grey once it states a fact
    /// (Following).
    private static func buttonConfiguration(
        for action: ProfileRelationshipsViewModel.RowAction
    ) -> UIButton.Configuration? {
        var configuration: UIButton.Configuration
        let title: String
        switch action {
        case .inert:
            return nil
        case .follow:
            configuration = .borderedProminent()
            title = "Follow"
        case .followBack:
            configuration = .borderedProminent()
            title = "Follow Back"
        case .following:
            configuration = .gray()
            title = "Following"
        case .requested:
            configuration = .gray()
            title = "Requested"
        }
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.appFont(forTextStyle: .subheadline)
        ]))
        return configuration
    }

    /// The button's own VoiceOver label names the person: the row and the
    /// button are separate elements, so "Follow" alone would be ambiguous in a
    /// list of forty.
    private static func actionLabel(for row: ProfileRelationshipsViewModel.Row) -> String? {
        switch row.action {
        case .inert: nil
        case .follow: "Follow \(row.displayName)"
        case .following: "Unfollow \(row.displayName)"
        case .followBack: "Follow \(row.displayName) back"
        case .requested: "Withdraw your request to \(row.displayName)"
        }
    }

    /// The name line: display name, then the verification seal, then "(Me)" on
    /// the viewer's own row.
    ///
    /// All three are one attributed string rather than extra accessories,
    /// because they belong to the *name* — they should sit against the last
    /// letter and travel with it as the text wraps or scales, where an
    /// accessory would pin them to the far edge of the row next to the action
    /// button. "(Me)" is set in the secondary colour and regular weight so it
    /// reads as an annotation on the name rather than part of it.
    private static func nameText(for row: ProfileRelationshipsViewModel.Row) -> NSAttributedString {
        let font = UIFont.appFont(forTextStyle: .headline)
        let name = NSMutableAttributedString(
            string: row.displayName,
            attributes: [.font: font, .foregroundColor: UIColor.label]
        )
        if row.isVerified {
            let seal = NSTextAttachment()
            seal.image = UIImage(
                systemName: "checkmark.seal.fill",
                withConfiguration: UIImage.SymbolConfiguration(font: font)
            )?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
            name.append(NSAttributedString(string: "\u{00A0}"))
            name.append(NSAttributedString(attachment: seal))
        }
        if row.isViewer {
            name.append(NSAttributedString(
                string: " (Me)",
                attributes: [
                    .font: UIFont.appFont(forTextStyle: .subheadline),
                    .foregroundColor: UIColor.secondaryLabel
                ]
            ))
        }
        return name
    }

    /// Dissolves the avatar in over the monogram once it resolves. Separate
    /// from `configure` so a snapshot re-apply that re-configures the same row
    /// doesn't restart a fetch that is already in flight.
    func loadAvatar(_ url: URL?) {
        guard url != currentAvatarURL || avatarView.image == nil else { return }
        currentAvatarURL = url
        avatarTask?.cancel()
        avatarView.image = nil

        guard let url, let pipeline = imagePipeline else { return }
        avatarTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, !Task.isCancelled, self.currentAvatarURL == url else { return }
            UIView.transition(
                with: self.avatarView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.avatarView.image = image
            }
        }
    }
}
