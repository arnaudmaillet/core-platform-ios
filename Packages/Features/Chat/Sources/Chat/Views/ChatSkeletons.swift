import DesignSystem
import UIKit

/// Skeleton loading surfaces for the chat screens, assembled from the design
/// system's `SkeletonBoneView` (one window-coherent shimmer band, shared
/// phase across every bone). Placeholder geometry reuses the real cells'
/// layout constants and stack recipes, so the cross-dissolve into content
/// reads as the same rows hydrating — not one screen replacing another.

/// The conversation list's first-load state: a top-anchored stack of rows
/// echoing `ConversationCell` — avatar circle, headline-weight title bone,
/// longer preview bone, small trailing time bone. Row heights land where the
/// real rows do because the internal stack recipe (insets, spacing, avatar
/// size) is the cell's own.
final class ConversationListSkeletonView: UIView {
    private enum Metrics {
        /// `ConversationCell.Metrics.avatarSize`.
        static let avatarSize: CGFloat = 48
        static let titleHeight: CGFloat = 13
        static let previewHeight: CGFloat = 11
        static let timeWidth: CGFloat = 34
        /// Bone widths cycle these fractions of the text column so the stack
        /// reads as organic content, not a repeated stamp.
        static let titleFractions: [CGFloat] = [0.42, 0.58, 0.36]
        static let previewFractions: [CGFloat] = [0.82, 0.64, 0.9]
        /// One row's silhouette height: the avatar plus its symmetric vertical
        /// margins (matches the real cell). The row *count* is derived from
        /// this at layout time, so the stack fills any viewport — SE through
        /// Max — instead of a hard-coded tally that leaves the short screens
        /// tall and the tall screens gapped at the bottom.
        static let rowHeight: CGFloat = avatarSize + Spacing.sm * 2
    }

    private let rows = UIStackView()
    /// The row count currently built into `rows`; guards `layoutSubviews`
    /// against rebuilding the stack on every pass — only a genuine height
    /// change (rotation, split-view resize) re-derives it.
    private var builtRowCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // The last row is rounded up to overshoot the bottom edge; clip so it
        // crops cleanly instead of leaving a partial-row gap on viewports that
        // aren't an exact multiple of the row height.
        clipsToBounds = true

        rows.axis = .vertical
        addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildRowsIfNeeded()
    }

    /// Rebuilds the stack to as many rows as the current height fits (rounding
    /// up so the bottom row clips at the edge rather than leaving a gap). A
    /// no-op unless the fitting count changed since the last build.
    private func rebuildRowsIfNeeded() {
        let height = bounds.height
        guard height > 0 else { return }
        let count = max(1, Int((height / Metrics.rowHeight).rounded(.up)))
        guard count != builtRowCount else { return }
        builtRowCount = count

        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        (0..<count).forEach { rows.addArrangedSubview(makeRow(at: $0)) }
    }

    private func makeRow(at index: Int) -> UIView {
        let avatar = SkeletonBoneView(rounding: .capsule)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Metrics.avatarSize)
        ])

        let title = SkeletonBoneView(rounding: .capsule)
        let time = SkeletonBoneView(rounding: .capsule)
        // A no-content spacer soaks up the width between title and time,
        // mirroring the real title row's hugging behavior.
        let slack = UIView()
        let titleRow = UIStackView(arrangedSubviews: [title, slack, time])
        titleRow.alignment = .center
        titleRow.spacing = Spacing.sm

        let preview = SkeletonBoneView(rounding: .capsule)
        let textColumn = UIStackView(arrangedSubviews: [titleRow, preview])
        textColumn.axis = .vertical
        textColumn.spacing = 6
        textColumn.alignment = .leading

        let row = UIStackView(arrangedSubviews: [avatar, textColumn])
        row.alignment = .center
        row.spacing = Spacing.md
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg
        )

        NSLayoutConstraint.activate([
            titleRow.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
            title.heightAnchor.constraint(equalToConstant: Metrics.titleHeight),
            title.widthAnchor.constraint(
                equalTo: textColumn.widthAnchor,
                multiplier: Metrics.titleFractions[index % Metrics.titleFractions.count]
            ),
            time.heightAnchor.constraint(equalToConstant: Metrics.previewHeight),
            time.widthAnchor.constraint(equalToConstant: Metrics.timeWidth),
            preview.heightAnchor.constraint(equalToConstant: Metrics.previewHeight),
            preview.widthAnchor.constraint(
                equalTo: textColumn.widthAnchor,
                multiplier: Metrics.previewFractions[index % Metrics.previewFractions.count]
            )
        ])
        return row
    }
}

/// The thread's first-load state: alternating incoming/outgoing bubble bones
/// anchored to the BOTTOM — a transcript lives at its tail — with the stack's
/// top free to clip under the nav bar like scrolled-away history. Bubble
/// spans and corner radius are `MessageCell`'s own constants; heights echo
/// one-, two-, and three-line bubbles.
final class TranscriptSkeletonView: UIView {
    private enum Metrics {
        /// `MessageCell.Metrics.cornerRadius` / `.maxWidthFraction`.
        static let cornerRadius: CGFloat = 18
        static let maxWidthFraction: CGFloat = 0.75
        /// One believable exchange, oldest first. Width is a fraction of the
        /// real bubbles' maximum span; heights are line-count silhouettes.
        static let pattern: [(isMine: Bool, width: CGFloat, height: CGFloat)] = [
            (false, 0.72, 56), (true, 0.55, 36), (false, 0.4, 36), (true, 0.85, 56),
            (false, 0.62, 44), (true, 0.45, 36), (false, 0.8, 56), (true, 0.58, 44),
            (false, 0.5, 36), (true, 0.7, 56), (false, 0.65, 44), (true, 0.42, 36)
        ]
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // Overflow above the visible band is scrolled-away history: clip it.
        clipsToBounds = true

        let bubbles = UIStackView(arrangedSubviews: Metrics.pattern.map(makeBubbleRow))
        bubbles.axis = .vertical
        bubbles.spacing = Spacing.sm
        addSubview(bubbles)
        bubbles.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bubbles.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.md),
            bubbles.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            bubbles.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeBubbleRow(_ entry: (isMine: Bool, width: CGFloat, height: CGFloat)) -> UIView {
        let bubble = SkeletonBoneView(rounding: .fixed(Metrics.cornerRadius))
        let row = UIView()
        row.addSubview(bubble)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.heightAnchor.constraint(equalToConstant: entry.height),
            bubble.widthAnchor.constraint(
                equalTo: row.widthAnchor, multiplier: Metrics.maxWidthFraction * entry.width
            ),
            entry.isMine
                ? bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor)
                : bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor)
        ])
        return row
    }
}
