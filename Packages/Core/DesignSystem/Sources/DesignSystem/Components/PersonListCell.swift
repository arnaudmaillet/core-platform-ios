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
        buildTextColumn()
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
        // ⚠️ The gap BETWEEN the two lines counts. It used to be hidden inside
        // `UIListContentConfiguration`; now the column owns it, and leaving it
        // out quietly shortened every row by the size of that gap.
        ceil(twoLineTextHeight + Spacing.xs + Spacing.lg * 2)
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

    /// The row's text, laid out by hand rather than by
    /// `UIListContentConfiguration`.
    ///
    /// ⚠️ **The second line needs two labels that truncate independently**, and
    /// a content configuration has exactly one `secondaryText`. Put the context
    /// in that string and it shares the handle's truncation: a long handle on a
    /// narrow screen swallows it. Put it in a trailing ACCESSORY instead — the
    /// first thing tried — and it is correct but detached, sitting at the row's
    /// outer edge like a timestamp rather than reading as part of the handle
    /// line. Owning the column is what buys "handle gives way, context stays,
    /// both on the same line".
    ///
    /// What that costs, and is paid for below: the system's type ramp, its
    /// margins, and its self-sizing all become this cell's job.
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let separatorLabel = UILabel()
    private let contextLabel = UILabel()
    private lazy var subtitleRow = UIStackView(
        arrangedSubviews: [handleLabel, separatorLabel, contextLabel]
    )
    private lazy var textColumn = UIStackView(arrangedSubviews: [nameLabel, subtitleRow])
    /// The text column's top and bottom pins, held so the row's height can be
    /// set by widening them.
    ///
    /// ⚠️ **A `>=` height constraint does not work here**, on the content view
    /// OR on the column: the content view is frame-driven, so anything below
    /// required gets broken to fit it and anything at required fights UIKit's
    /// own encapsulated height. Growing the MARGINS is unambiguous — every
    /// constraint stays required, and the row is exactly as tall as the
    /// arithmetic says.
    private var topPin: NSLayoutConstraint?
    private var bottomPin: NSLayoutConstraint?

    private func buildTextColumn() {
        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.textColor = .label
        handleLabel.font = .preferredFont(forTextStyle: .subheadline)
        handleLabel.textColor = .secondaryLabel
        // Same size and weight as the handle, one step quieter in colour: the
        // context is a peer of the handle, not a second subtitle competing
        // with it, and not something the eye should land on first.
        contextLabel.font = .preferredFont(forTextStyle: .subheadline)
        contextLabel.textColor = .tertiaryLabel
        separatorLabel.font = .preferredFont(forTextStyle: .subheadline)
        separatorLabel.textColor = .tertiaryLabel
        separatorLabel.text = "•"

        for label in [nameLabel, handleLabel, separatorLabel, contextLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        // The handle is the only thing on the line that may lose characters.
        handleLabel.lineBreakMode = .byTruncatingTail
        handleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [separatorLabel, contextLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        subtitleRow.axis = .horizontal
        subtitleRow.alignment = .firstBaseline
        subtitleRow.spacing = Spacing.xs
        textColumn.axis = .vertical
        textColumn.alignment = .leading
        // Enough to separate the two lines without opening a gap the disc has
        // to span; the row's height budget is set by `minimumRowHeight`.
        textColumn.spacing = Spacing.xs
        // ⚠️ The leading inset is the gap to the DISC. UIKit already insets
        // `contentView` past a leading accessory, but it leaves no air between
        // them — without this the name starts hard against the avatar.
        let top = textColumn.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Metrics.verticalMargin
        )
        let bottom = contentView.bottomAnchor.constraint(
            equalTo: textColumn.bottomAnchor, constant: Metrics.verticalMargin
        )
        topPin = top
        bottomPin = bottom
        textColumn.constrain(in: contentView) { parent in
            top
            bottom
            textColumn.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Spacing.lg)
            textColumn.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        }
        // ⚠️ And the separator follows the TEXT, not the cell. A list cell
        // aligns its separator to whatever the content configuration drew;
        // with a hand-built column it has nothing to follow and runs the full
        // width, under the avatar, which reads as a different list. This is
        // the documented hook for saying where the text starts.
        separatorLayoutGuide.leadingAnchor.constraint(
            equalTo: textColumn.leadingAnchor
        ).isActive = true
    }

    private enum Metrics {
        /// Above and below the text column. Chosen so a two-line row lands
        /// where `UIListContentConfiguration` used to put it — this cell drew
        /// itself with the system's margins until the second line needed two
        /// independently truncating labels, and the compose picker and inbox
        /// search should not shift because of a change they did not ask for.
        static let verticalMargin = Spacing.md
    }

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

        nameLabel.attributedText = Self.nameText(for: model)
        handleLabel.text = model.handle
        // Hidden, not empty: a stack view skips a hidden arranged subview
        // entirely, so a handle-less row collapses to one line and a
        // context-less row shows no stray bullet.
        handleLabel.isHidden = model.handle.isEmpty
        contextLabel.text = model.context.label
        contextLabel.isHidden = model.context.label == nil
        // The bullet only earns its place between two things.
        separatorLabel.isHidden = handleLabel.isHidden || contextLabel.isHidden
        subtitleRow.isHidden = handleLabel.isHidden && contextLabel.isHidden

        // Whatever margin it takes to reach the target from THIS row's text —
        // more for a one-line row than a two-line one, which is exactly what
        // makes the two land on the same height.
        let columnHeight = subtitleRow.isHidden
            ? UIFont.preferredFont(forTextStyle: .headline).lineHeight
            : Self.twoLineTextHeight + textColumn.spacing
        let margin = max(Metrics.verticalMargin, (minimumRowHeight - columnHeight) / 2)
        topPin?.constant = margin
        bottomPin?.constant = margin

        // The disc, and a ✕ only where the host asked for one. A row that
        // needs a whole action COLUMN is not this row — see
        // `RelationshipListCell`, which is this anatomy with a follow button
        // and stays its own type because of it.
        deleteHost.button.accessibilityLabel = "Remove \(model.displayName)"
        accessories = onDelete == nil ? [avatarHost.leadingAccessory] : [
            avatarHost.leadingAccessory,
            .customView(configuration: .init(
                customView: deleteHost,
                placement: .trailing(displayed: .always),
                reservedLayoutWidth: .actual
            ))
        ]

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
