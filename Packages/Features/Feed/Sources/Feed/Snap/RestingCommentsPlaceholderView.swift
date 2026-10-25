import DesignSystem
import MediaCore
import UIKit

/// What a text page shows where its resting comments panel will be, for the
/// duration of the flight that brings the page on.
///
/// ⚠️ **BEHIND `-defer-resting-comments` (charter PR 5b), AND THE REASON IS A
/// MEASUREMENT.** A text page's caption lives INSIDE its comments panel, so
/// the page used to mount a whole `PostDetailViewController` — a collection
/// view, a composer bar, a stream — in `willDisplay`, inside the run-loop
/// turn that sets the hero flight up. `-presentation-budget` put that mount
/// at roughly a fifth of the largest screen turn in the app. This view is
/// what stands in its place until the flight lands: the caption as a real
/// row (the same `CommentRowView` the panel's first row is, configured the
/// same way, so the text reveal lands on the same pixels) and the comment
/// rows as the same bones the panel draws while its comments load — at the
/// stream's own insets, so the swap to the real panel moves nothing.
///
/// No collection view, no view controller, no data source: a stack of views
/// built once. It is removed once the real panel has been mounted over it.
final class RestingCommentsPlaceholderView: UIView {
    private let stack = UIStackView()
    private let caption = CommentRowView(installsContextMenu: false)
    private var rows: [CommentSkeletonRowView] = []
    private var topInset: NSLayoutConstraint!

    init(model: FeedItemDisplayModel, imagePipeline: ImagePipeline, safeAreaTop: CGFloat) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true

        stack.axis = .vertical
        stack.alignment = .fill
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The stream's geometry: its content inset at the top, the section's
        // horizontal insets, and each row's own bottom gap.
        topInset = stack.topAnchor.constraint(
            equalTo: topAnchor, constant: SnapCommentsLayout.commentsTopInset(topInset: safeAreaTop)
        )
        NSLayoutConstraint.activate([
            topInset,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
        ])

        if let text = model.caption, !text.isEmpty {
            caption.configureAsPostCaption(
                authorName: model.authorName,
                timestamp: model.timestampText,
                caption: text,
                monogram: CommentsInputBar.monogram(model.authorName),
                avatarURL: model.avatarURL,
                likeCount: model.cardMetrics?.reactions ?? model.likeCount,
                imagePipeline: imagePipeline
            )
            stack.addArrangedSubview(Self.gapped(caption))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Updates the stream's top inset once the cell knows its safe area.
    func setSafeAreaTop(_ safeAreaTop: CGFloat) {
        topInset.constant = SnapCommentsLayout.commentsTopInset(topInset: safeAreaTop)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Enough bones to reach the bottom edge, the way the panel counts
        // its placeholders against the viewport.
        let needed = SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: bounds.height)
        guard needed != rows.count else { return }
        rows.forEach { $0.superview?.removeFromSuperview() }
        rows = (0..<needed).map(CommentSkeletonRowView.init(index:))
        rows.forEach { stack.addArrangedSubview(Self.gapped($0)) }
    }

    /// A row with the cell's bottom gap under it.
    private static func gapped(_ row: UIView) -> UIView {
        let host = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Spacing.lg),
        ])
        return host
    }
}
