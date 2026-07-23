import DesignSystem
import UIKit

/// The stacked "accent bar + author + snippet" widget that previews a quoted
/// message. Shared by the two surfaces that show one: the quote inside a reply
/// bubble (`MessageCell`) and the active-reply preview in the compose bar
/// (`ChatInputBar`). Each host sets the text and tints it to read on its own
/// background, and supplies its own framing (rounded fill, close button, …).
final class QuotedReplyView: UIView {
    static let accentWidth: CGFloat = 3

    private let accent = UIView()
    private let authorLabel = UILabel()
    private let snippetLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        accent.layer.cornerRadius = Self.accentWidth / 2

        authorLabel.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        authorLabel.adjustsFontForContentSizeCategory = true

        snippetLabel.font = .preferredFont(forTextStyle: .caption1)
        snippetLabel.adjustsFontForContentSizeCategory = true
        snippetLabel.numberOfLines = 1
        snippetLabel.lineBreakMode = .byTruncatingTail
        // Never widen the host to fit the full snippet — truncate instead.
        snippetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = UIStackView(arrangedSubviews: [authorLabel, snippetLabel])
        column.axis = .vertical
        column.spacing = 1

        addSubview(accent)
        accent.constrain(in: self) { parent in
            accent.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            accent.topAnchor.constraint(equalTo: parent.topAnchor)
            accent.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            accent.widthAnchor.constraint(equalToConstant: Self.accentWidth)
        }
        column.constrain(in: self) { parent in
            column.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: Spacing.sm)
            column.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            column.topAnchor.constraint(equalTo: parent.topAnchor)
            column.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setContent(author: String, snippet: String) {
        authorLabel.text = author
        snippetLabel.text = snippet
    }

    /// Recolors the three elements to read on the host's background.
    func tint(accent: UIColor, author: UIColor, snippet: UIColor) {
        self.accent.backgroundColor = accent
        authorLabel.textColor = author
        snippetLabel.textColor = snippet
    }
}
