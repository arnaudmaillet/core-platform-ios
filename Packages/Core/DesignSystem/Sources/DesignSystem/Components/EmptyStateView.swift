import UIKit

/// What a surface shows when it has nothing to show: a glyph, a headline, an
/// optional line of explanation, and an optional way out.
///
/// **The job is to say "this is an answer", not "this is broken".** A blank
/// region reads as a failure — a request that never returned, a screen that did
/// not finish — and the difference between that and "there is genuinely nothing
/// here" is the whole reason this exists. So the title states the finding and
/// the subtitle is where a surface explains WHY it might be narrower than
/// expected (a filter, a context, a search term), which is what turns a dead end
/// into something the viewer can act on.
///
/// **Centred in its parent, always.** It is pinned to the centre rather than
/// laid out from the top, so it does not drift with content insets, and it takes
/// the readable width so a long sentence wraps rather than running edge to edge.
public final class EmptyStateView: UIView {
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private lazy var actionButton = UIButton(configuration: .borderless())
    private let stack = UIStackView()
    private var actionHandler: (() -> Void)?

    /// The glyph's point size. Large enough to anchor the block, small enough
    /// that it never competes with the words — the sentence is the message.
    private static let iconPointSize: CGFloat = 34

    /// The widest the text is allowed to get. Sentences set much wider than a
    /// paragraph become hard to track back to the next line, and an empty state
    /// on an iPad would otherwise stretch to the full width of the screen.
    private static let readableWidth: CGFloat = 320

    public init() {
        super.init(frame: .zero)

        icon.contentMode = .scaleAspectFit
        icon.tintColor = .tertiaryLabel
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: Self.iconPointSize, weight: .regular
        )
        icon.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        for label in [titleLabel, subtitleLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            // Unbounded: an empty state that truncates its own explanation is
            // worse than one that is a line taller.
            label.numberOfLines = 0
        }

        actionButton.addAction(
            UIAction { [weak self] _ in self?.actionHandler?() }, for: .primaryActionTriggered
        )

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.sm
        [icon, titleLabel, subtitleLabel, actionButton].forEach(stack.addArrangedSubview)
        // A little more air above the action than between the lines of text, so
        // it reads as a separate offer rather than a third line.
        stack.setCustomSpacing(Spacing.lg, after: subtitleLabel)
        stack.setCustomSpacing(Spacing.md, after: icon)

        stack.constrain(in: self) { parent in
            stack.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            stack.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.readableWidth)
            // The margins win when the screen is narrower than the readable
            // width; `<=` on both means neither has to know about the other.
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: parent.layoutMarginsGuide.leadingAnchor
            )
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: parent.layoutMarginsGuide.trailingAnchor
            )
        }

        // The whole block reads as one statement to VoiceOver rather than three
        // fragments; the action keeps its own element, because it is the one
        // part that DOES something.
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sets the whole state at once.
    ///
    /// One call rather than four properties, because these are facets of a
    /// single message and setting them independently invites a half-updated
    /// state — a title from one condition beside a subtitle from another.
    /// Absent parts are hidden, so a caller supplies only what it can say.
    public func configure(
        symbolName: String? = nil,
        title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        actionHandler: (() -> Void)? = nil
    ) {
        configure(
            image: symbolName.flatMap { UIImage(systemName: $0) },
            title: title,
            subtitle: subtitle,
            actionTitle: actionTitle,
            actionHandler: actionHandler
        )
    }

    /// The image-taking form, for a caller whose glyph is not an SF Symbol.
    public func configure(
        image: UIImage?,
        title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        actionHandler: (() -> Void)? = nil
    ) {
        icon.image = image
        icon.isHidden = image == nil

        titleLabel.text = title
        titleLabel.isHidden = title.isEmpty

        subtitleLabel.text = subtitle
        // Emptiness counts as absence: a caller that computes a subtitle and
        // sometimes gets "" should not leave a blank line in the middle of the
        // block.
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true

        // The handler is what makes the button real. A title with nothing
        // behind it would be an offer the view cannot keep.
        self.actionHandler = actionHandler
        let showsAction = actionTitle?.isEmpty == false && actionHandler != nil
        actionButton.isHidden = !showsAction
        actionButton.configuration?.title = showsAction ? actionTitle : nil

        accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ". ")
    }
}
