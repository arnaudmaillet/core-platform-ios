import DesignSystem
import UIKit

/// A row of the comments panel that leads further into it (#2298):
///
/// - **Popular's last, "See all n comments"**: Popular shows only the
///   threads that fit its room (`PopularCommentsCut`); this turns to Recent,
///   the tab's own change, the selector following.
/// - **Recent's first, "Earlier comments"**: older comments load on this
///   tap only, never by themselves as the reader scrolls up, so the top of
///   what is loaded is a real edge. A small loader while the page is on its
///   way, a retry in place if it fails.
///
/// Drawn as the thread folds are (`CommentThreadToggleRow`): the footnote
/// type in the secondary colour, at the replies' column, its chevron
/// pointing where it leads. The whole row is the target.
final class CommentStreamLinkCell: UICollectionViewCell {
    /// Where the row stands with what it leads to.
    enum State: Equatable {
        case idle
        /// The page it asked for is on its way.
        case loading
        /// The page it asked for failed: a tap asks again.
        case failed
    }

    /// What the row says and where its chevron points.
    struct Content: Equatable {
        var title: String
        var symbol: String
        var state: State = .idle
        var identifier: String
    }

    var onTap: (() -> Void)?

    private let label = UILabel()
    private let chevron = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private(set) var content: Content?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .appFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        // ⚠️ ONE HEIGHT IN EVERY STATE: the spinner stands OVER the chevron,
        // out of the layout. In the row it was taller than the footnote line
        // (20 pt against ~15.7), so the row grew as its page started to load
        // and pushed the rows under it down by the difference — the list
        // moved at the tap, before the page that must not move it had even
        // landed — and shrank again off screen, where a self-sizing list
        // doesn't measure it, so the move stayed.
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let row = UIStackView(arrangedSubviews: [label, chevron])
        row.axis = .horizontal
        row.spacing = Spacing.xs
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        contentView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: chevron.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: CommentRowView.replyIndent),
            row.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.xs),
            // The thread folds' breath under the row (`seamCell`).
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -(Spacing.xs + Spacing.lg)),
        ])
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ content: Content) {
        self.content = content
        label.text = content.state == .failed ? Self.failedTitle : content.title
        chevron.image = UIImage(
            systemName: content.state == .failed ? "arrow.clockwise" : content.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        )
        // Hidden by alpha, never `isHidden`: the stack keeps its place.
        chevron.alpha = content.state == .loading ? 0 : 1
        if content.state == .loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        accessibilityIdentifier = content.identifier
        accessibilityLabel = label.text
        accessibilityTraits = content.state == .loading ? [.button, .notEnabled] : .button
    }

    /// What a failed page says, in place of the row's title.
    /// Short, so it takes the line the title took: a row that wrapped on
    /// failure would move the list as well.
    static let failedTitle = "Couldn't load. Try Again"

    @objc private func tapped() {
        guard content?.state != .loading else { return }
        onTap?()
    }

    override func accessibilityActivate() -> Bool {
        tapped()
        return true
    }

    /// The row's height at `width`, for the cut (`PopularCommentsCut`):
    /// measured through the cell itself, never displayed.
    static func height(of content: Content, width: CGFloat, sizing cell: CommentStreamLinkCell) -> CGFloat {
        guard width > 0 else { return 0 }
        cell.configure(content)
        cell.bounds.size.width = width
        cell.contentView.setNeedsLayout()
        cell.contentView.layoutIfNeeded()
        return ceil(cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height)
    }
}
