import UIKit

/// The app's person row: identity disc, display name (with its seal), handle.
///
/// A plain `UICollectionViewListCell` carrying a system content configuration,
/// with the identity disc hung off it as a *leading accessory* rather than
/// laid out by hand. That is what keeps the row vanilla: the list cell keeps
/// ownership of its separators (inset past the accessory automatically), its
/// selection and highlight states, and its Dynamic Type metrics — none of
/// which a custom content view gets for free.
///
/// Lives here rather than in Chat, where it was written, because three
/// features now render the same row: the compose picker, the inbox's search
/// results, and the search screen. It reads `PersonRowContent` — four strings
/// and a flag — rather than any feature's display model, which is what let it
/// move at all: the old signature took a type carrying a `ProfileID`, and
/// DesignSystem depends on nothing.
public final class PersonListCell: UICollectionViewListCell {
    /// Created once per cell and handed back to the accessory on every
    /// configure — accessories replace their custom view wholesale, and
    /// allocating a fresh disc per reuse would churn a view per scrolled row.
    /// `MonogramAccessoryHost` documents why the disc needs a host at all.
    private let avatarHost = MonogramAccessoryHost()

    // Stated even though the body is empty: declaring ANY initializer suppresses
    // inheritance of the superclass's designated ones, so without this the
    // `init?(coder:)` below leaves `init(frame:)` an unimplemented stub — which
    // compiles cleanly and traps the first time the list dequeues a cell.
    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A floor under the row's height, so a list that mixes one-line and
    /// two-line rows keeps one rhythm.
    ///
    /// **The row is TEXT-bound, which is the whole subtlety.** A person's row
    /// is two lines and a query's is one, so the same margins leave them 16pt
    /// apart and the shorter rows read as a denser list. The disc does not
    /// save it either — 48pt fits inside both — so the height is settled by
    /// type, and the only lever that reaches a one-line row is its own margin.
    /// `configure` therefore computes the margin PER ROW: whatever it takes to
    /// land on the same total.
    ///
    /// ⚠️ Two things that look like the fix and are not, both tried: a
    /// `>=` height constraint on `contentView` (the cell owns that frame and
    /// ignores it) and a taller leading accessory (accessories are laid out
    /// inside the row's height, they do not set it).
    ///
    /// Opt-in (`0` = whatever the content configuration says) because it is a
    /// decision about a LIST, not about a row: the compose picker is all
    /// people, every row there is already the same height, and it would be
    /// paying for a problem it does not have.
    public var minimumRowHeight: CGFloat = 0

    /// The row height the app's people lists breathe at: two lines of type
    /// with a generous margin above and below.
    ///
    /// Computed from the fonts rather than fixed, so it tracks Dynamic Type —
    /// a constant would clip the text at the larger sizes.
    public static var comfortableRowHeight: CGFloat {
        ceil(twoLineTextHeight + Spacing.lg * 2)
    }

    private static var twoLineTextHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .headline).lineHeight
            + UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
    }

    /// Fires when the trailing ✕ is tapped. Passed to `configure` rather than
    /// assigned afterwards: whether the row HAS a ✕ is decided while its
    /// accessories are being built, and a handler set a line later would arrive
    /// after that decision had already been made without it.
    private var onDelete: (() -> Void)?

    /// Frame-based host for the ✕, sized by a constant rather than by the
    /// button inside it.
    ///
    /// ⚠️ **A bare `UIButton` as the accessory looks right and is not
    /// tappable.** It shipped that way once and was caught in the simulator:
    /// the glyph drew in the correct place, but tapping it selected the row.
    /// `UIButton.Configuration` resolves at the button's next update pass, not
    /// on assignment, so when the accessory reserves `.actual` width at
    /// install time the button still reports no intrinsic size — a zero-width
    /// slot, and hit-testing misses a control the eye can plainly see.
    private final class DeleteAccessoryView: UIView {
        /// A 44pt square: the art is a small glyph, and the tappable area
        /// should be the standard target rather than the size of the drawing.
        static let side: CGFloat = 44

        let button = UIButton(type: .system)

        override var intrinsicContentSize: CGSize {
            CGSize(width: Self.side, height: Self.side)
        }

        init() {
            super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: "xmark")
            configuration.baseForegroundColor = .tertiaryLabel
            configuration.contentInsets = .zero
            button.configuration = configuration
            button.pin(to: self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    /// The trailing context label.
    ///
    /// A bare `UILabel` can be a custom accessory directly: UIKit asserts that
    /// accessory views keep `translatesAutoresizingMaskIntoConstraints`
    /// enabled, and a label sizes itself intrinsically without constraints on
    /// itself. (`MonogramAvatarView` cannot, which is what
    /// `MonogramAccessoryHost` exists to work around.) The inbox's
    /// `ConversationResultCell` carries its timestamp the same way.
    ///
    /// ⚠️ **An accessory, not a second line of text.** As part of the content
    /// configuration it would share one truncation with the handle, and a long
    /// handle on a narrow screen would eat the context entirely. An accessory
    /// reserves its width first and the NAME and HANDLE truncate into what is
    /// left — which is the behaviour the row wants: the context is short,
    /// bounded, and the thing you can least afford to lose half of.
    private lazy var contextLabel: UILabel = {
        let label = UILabel()
        // Tertiary and a size below the handle: this is the quietest thing in
        // the row and must not compete with the name or read as a second
        // handle.
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .tertiaryLabel
        label.adjustsFontForContentSizeCategory = true
        // The label never shrinks; the name and handle give way instead.
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()

    private lazy var deleteHost: DeleteAccessoryView = {
        let host = DeleteAccessoryView()
        host.button.addAction(
            UIAction { [weak self] _ in self?.onDelete?() }, for: .primaryActionTriggered
        )
        return host
    }()

    public override func prepareForReuse() {
        super.prepareForReuse()
        // A recycled row must not wear the previous person's face for the
        // moment before its own picture arrives — or forever, if it has none.
        avatarHost.reset()
        onDelete = nil
    }

    /// The picture for this row, once its caller has one. Rows without an
    /// avatar simply never call it and keep their initials.
    public func setAvatarImage(_ image: UIImage?) {
        avatarHost.setImage(image)
    }

    /// `onDelete` non-nil is what puts a ✕ on the row; every host but the
    /// search history leaves it out and gets a row with no trailing affordance.
    public func configure(with model: PersonRowContent, onDelete: (() -> Void)? = nil) {
        self.onDelete = onDelete
        switch model.subject {
        case .person: avatarHost.setMonogram(model.monogram)
        case .symbol(let systemName): avatarHost.setSymbol(systemName)
        }

        var content = UIListContentConfiguration.subtitleCell()
        content.attributedText = Self.nameText(for: model)
        // One two-line shape everywhere — name over handle, disc centred across
        // both. `nil` (not "") on the rare handle-less row so it collapses to
        // one line rather than leaving a gap under the name.
        content.secondaryText = model.handle.isEmpty ? nil : model.handle
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)

        if minimumRowHeight > 0 {
            var margins = content.directionalLayoutMargins
            // ⚠️ The target is never below what a two-line row is ALREADY.
            // Taking the requested minimum alone left the two-line rows on
            // their own (larger) default margins while the one-line rows were
            // lifted to the smaller target — so they still did not match, just
            // by less. The natural two-line height is the floor.
            let naturalHeight = Self.twoLineTextHeight + margins.top + margins.bottom
            let target = max(minimumRowHeight, naturalHeight)
            // Whatever it takes to reach the target from THIS row's text —
            // more for a one-line row than a two-line one, which is exactly
            // what makes the two land on the same height.
            let textHeight = content.secondaryText == nil
                ? UIFont.preferredFont(forTextStyle: .headline).lineHeight
                : Self.twoLineTextHeight
            let margin = max(margins.top, (target - textHeight) / 2)
            margins.top = margin
            margins.bottom = margin
            content.directionalLayoutMargins = margins
        }
        contentConfiguration = content

        // The disc, and a ✕ only where the host asked for one. A row that
        // needs a whole action COLUMN is not this row — see
        // `RelationshipListCell`, which is this anatomy with a follow button
        // and stays its own type because of it.
        deleteHost.button.accessibilityLabel = "Remove \(model.displayName)"
        contextLabel.text = model.context.label

        // Order matters: the context sits inside the ✕, so the remove button
        // stays on the row's outer edge where a trailing action belongs.
        var trailing: [UICellAccessory] = []
        if model.context.label != nil {
            trailing.append(.customView(configuration: .init(
                customView: contextLabel,
                placement: .trailing(displayed: .always),
                reservedLayoutWidth: .actual
            )))
        }
        if onDelete != nil {
            trailing.append(.customView(configuration: .init(
                customView: deleteHost,
                placement: .trailing(displayed: .always),
                reservedLayoutWidth: .actual
            )))
        }
        accessories = [avatarHost.leadingAccessory] + trailing

        accessibilityLabel = [model.displayName, model.handle, model.context.label]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The name, with the verification seal inline after it.
    ///
    /// An attachment rather than a second accessory: the badge belongs to the
    /// name — it should sit against the last letter and move with it when the
    /// text wraps or scales — where a trailing accessory would pin it to the
    /// far edge of the row, next to the progress spinner.
    private static func nameText(for model: PersonRowContent) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .headline)
        let name = NSMutableAttributedString(
            string: model.displayName,
            attributes: [.font: font, .foregroundColor: UIColor.label]
        )
        guard model.isVerified else { return name }

        let seal = NSTextAttachment()
        seal.image = UIImage(
            systemName: "checkmark.seal.fill",
            withConfiguration: UIImage.SymbolConfiguration(font: font)
        )?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        name.append(NSAttributedString(string: "\u{00A0}"))
        name.append(NSAttributedString(attachment: seal))
        return name
    }
}
