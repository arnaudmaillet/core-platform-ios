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
    /// The header line's trailing control: ♥ + counter, pushed to the far
    /// right of the name/time axis by the header label's stretch (the
    /// dynamic spacer) — and anchored to the row's trailing edge, which
    /// the engaged layout already stops at the reactions rail's boundary
    /// (`setEngagedInsets(trailing:)`), so the counter can never sit
    /// under the rail.
    private let likeButton = UIButton(configuration: .plain())

    /// Avatar tapped — push the author's profile.
    var onAvatarTap: (() -> Void)?
    /// The header's ♥ tapped. Like state is the HOST's affair (session-
    /// local optimistic toggle — the bookmark posture; comment.v1 carries
    /// no like API yet).
    var onLikeTap: (() -> Void)?
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
        // The row's reply tap is FILTERED (see the gesture delegate):
        // touches on the avatar or any control (the like button) keep
        // their own actions exclusive — without the filter the row tap
        // fires alongside them.
        let rowTap = UITapGestureRecognizer(target: self, action: #selector(rowTapped))
        rowTap.delegate = self
        addGestureRecognizer(rowTap)
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @objc private func avatarTapped() { onAvatarTap?() }
    @objc private func rowTapped() { onReplyTap?() }

    /// Renders the like control's state: filled pink heart when liked,
    /// quiet outline otherwise; the counter shows only a real number
    /// (zero renders bare — no lying "0").
    func setLiked(_ liked: Bool, count: Int) {
        var config = likeButton.configuration
        config?.image = UIImage(
            systemName: liked ? "heart.fill" : "heart",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )
        config?.baseForegroundColor = liked ? .systemPink : .secondaryLabel
        if count > 0 {
            var title = AttributedString(SnapSubtitleView.countText(count))
            title.font = UIFont.preferredFont(forTextStyle: .caption1)
            config?.attributedTitle = title
        } else {
            config?.attributedTitle = nil
        }
        likeButton.configuration = config
    }

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

        likeButton.configuration?.imagePadding = 3
        likeButton.configuration?.contentInsets = .zero
        // COUNT LEFT OF HEART: the button is trailing-anchored, so with
        // the glyph at the trailing edge the control grows LEFTWARD as
        // the counter appears or gains digits — the heart never shifts
        // off its anchor.
        likeButton.configuration?.imagePlacement = .trailing
        likeButton.accessibilityLabel = "Like comment"
        likeButton.addAction(UIAction { [weak self] _ in self?.onLikeTap?() }, for: .primaryActionTriggered)
        setLiked(false, count: 0)

        // [Name · Time][———— stretch ————][♥ count]: the header label is
        // the designated absorber (hugging floor), the like control is
        // rigid — the label's stretch IS the dynamic spacer, and the
        // control lands on the exact name/time axis at the far right.
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerLabel.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        likeButton.setContentHuggingPriority(.required, for: .horizontal)
        likeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let headerRow = UIStackView(arrangedSubviews: [headerLabel, likeButton])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = Spacing.sm

        let textStack = UIStackView(arrangedSubviews: [headerRow, bodyLabel])
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

extension CommentRowView: UIGestureRecognizerDelegate {
    /// The row-tap filter: the reply trigger yields wherever a touch
    /// belongs to a control (the like button) or the avatar — their
    /// actions stay exclusive instead of firing alongside the reply.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer.view === self else { return true }
        var view = touch.view
        while let current = view, current !== self {
            if current is UIControl || current === avatarView { return false }
            view = current.superview
        }
        return true
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

/// A popular thread's fold seam, standing at reply depth so it reads as
/// part of the thread it toggles: "View N more replies… ∨" while
/// collapsed, "Hide replies ∧" while expanded — one row, two faces, the
/// inverse actions of the same fold.
final class CommentThreadToggleRow: UIView {
    enum Kind: Equatable {
        case expand(hidden: Int)
        case collapse
    }

    var onTap: (() -> Void)?
    /// The thread this seam folds — the host finds the surviving seam
    /// after a collapse re-render to keep the user's place.
    let parentID: String

    init(kind: Kind, parentID: String) {
        self.parentID = parentID
        super.init(frame: .zero)
        let label = UILabel()
        let chevronName: String
        switch kind {
        case .expand(let hidden):
            label.text = "View \(hidden) more \(hidden == 1 ? "reply" : "replies")…"
            chevronName = "chevron.down"
        case .collapse:
            label.text = "Hide replies"
            chevronName = "chevron.up"
        }
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        let chevron = UIImageView(image: UIImage(
            systemName: chevronName,
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
