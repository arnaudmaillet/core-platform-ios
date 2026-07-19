import DesignSystem
import UIKit

/// A single comment: monogram avatar, "Name · time" header (display name
/// only — the @handle identifier was removed for reading comfort), and body.
/// Plain `UIView` (not a cell) — appended into the post-detail content stack.
///
/// Interactions, all host-wired seams:
/// - avatar tap → the author's profile (the outbound push lifecycle).
/// - row tap → the composer's reply state, bound to this thread.
/// - long press → the native context menu (share / block / report).
final class CommentRowView: UIView {
    private enum Metrics {
        static let avatarSize: CGFloat = 32
        /// The level-2 indentation: replies step in by one avatar column
        /// (avatar + its gap), the standard thread offset — a reply's
        /// avatar starts where its parent's text does.
        static let replyIndent: CGFloat = avatarSize + 8
    }

    /// Exposed for layout tests: the leading inset a reply row applies.
    static var replyIndent: CGFloat { Metrics.replyIndent }

    private let avatarView = UIView()
    private let monogramLabel = UILabel()
    private let headerLabel = UILabel()
    private let bodyLabel = UILabel()

    /// Avatar tapped — push the author's profile.
    var onAvatarTap: (() -> Void)?
    /// Row tapped — enter the composer's reply state for this thread.
    var onReplyTap: (() -> Void)?
    /// Context-menu actions. Share presents the system sheet; block and
    /// report are seams (no moderation backend yet — the repost/save
    /// posture: honest affordances, unwired mutations).
    var onShare: (() -> Void)?
    var onBlock: (() -> Void)?
    var onReport: (() -> Void)?

    init(model: CommentDisplayModel) {
        super.init(frame: .zero)
        configure(indented: model.isReply)
        headerLabel.text = "\(model.authorName) · \(model.metaText)"
        bodyLabel.text = model.body
        monogramLabel.text = model.monogram

        // The avatar's tap outranks the row's (recognizers resolve to the
        // deepest view); everything else on the row is the reply trigger.
        avatarView.isUserInteractionEnabled = true
        avatarView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(avatarTapped))
        )
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(rowTapped)))
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @objc private func avatarTapped() { onAvatarTap?() }
    @objc private func rowTapped() { onReplyTap?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure(indented: Bool) {
        avatarView.backgroundColor = .tertiarySystemFill
        avatarView.layer.cornerRadius = Metrics.avatarSize / 2
        avatarView.clipsToBounds = true
        monogramLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        monogramLabel.textColor = .secondaryLabel
        monogramLabel.textAlignment = .center
        monogramLabel.pin(to: avatarView)

        headerLabel.font = .preferredFont(forTextStyle: .footnote)
        headerLabel.adjustsFontForContentSizeCategory = true
        headerLabel.textColor = .secondaryLabel
        headerLabel.numberOfLines = 1

        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = .label
        bodyLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [headerLabel, bodyLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [avatarView, textStack])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Spacing.sm
        // Level-2 rows step in by the reply indent; level-1 rows fill the
        // width. The indent is the row's ONLY depth cue — same avatar,
        // same type — which is exactly the standard thread grammar.
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: indented ? Metrics.replyIndent : 0
            ),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize)
        ])
    }
}

extension CommentRowView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: "Share Comment",
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { _ in self?.onShare?() },
                UIAction(
                    title: "Block User",
                    image: UIImage(systemName: "hand.raised"),
                    attributes: .destructive
                ) { _ in self?.onBlock?() },
                UIAction(
                    title: "Report",
                    image: UIImage(systemName: "flag"),
                    attributes: .destructive
                ) { _ in self?.onReport?() },
            ])
        }
    }
}

/// The collapsed remainder of a popular thread: "View N more replies…",
/// standing at reply depth so it reads as part of the thread it expands.
final class CommentViewMoreRow: UIView {
    var onTap: (() -> Void)?

    init(hiddenCount: Int) {
        super.init(frame: .zero)
        let label = UILabel()
        label.text = "View \(hiddenCount) more \(hiddenCount == 1 ? "reply" : "replies")…"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        let chevron = UIImageView(image: UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        ))
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .center

        let row = UIStackView(arrangedSubviews: [label, chevron])
        row.axis = .horizontal
        row.spacing = Spacing.xs
        row.alignment = .center
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: CommentRowView.replyIndent
            ),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.xs),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityLabel = label.text
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func tapped() { onTap?() }
}
