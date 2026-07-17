import DesignSystem
import UIKit

/// One transcript bubble, self-sized by Auto Layout. A single cell class
/// serves both alignments: sender side, corner shaping, colors, and run
/// spacing all come from the row model on configure, so reuse never has to
/// tear structure down.
final class MessageCell: UICollectionViewCell {
    private enum Metrics {
        static let cornerRadius: CGFloat = 18
        /// The reduced radius on corners facing a same-run neighbor.
        static let groupedCornerRadius: CGFloat = 5
        static let maxWidthFraction: CGFloat = 0.75
        /// Gap above a bubble continuing a run vs. starting a new one.
        static let runSpacing: CGFloat = 2
        static let groupSpacing: CGFloat = Spacing.sm
    }

    /// The four resolved radii, left/right like `UICornerConfiguration`.
    private struct CornerRadii {
        var topLeft: CGFloat
        var topRight: CGFloat
        var bottomLeft: CGFloat
        var bottomRight: CGFloat
    }

    /// The bubble is a clear container; its rounded fill lives on this
    /// subview. The split is load-bearing for the context-menu lift: the
    /// system platter strips a targeted preview VIEW's own background (it
    /// repaints from `UIPreviewParameters`), but faithfully portals subview
    /// content — a fill carried by a subview rides the lift, hover, and
    /// return flight without ghosting.
    private let bubble = UIView()
    private let bubbleBackground = UIView()
    private let bodyLabel = UILabel()
    private let timeLabel = UILabel()
    private var radii = CornerRadii(
        topLeft: Metrics.cornerRadius, topRight: Metrics.cornerRadius,
        bottomLeft: Metrics.cornerRadius, bottomRight: Metrics.cornerRadius
    )

    private var topConstraint: NSLayoutConstraint!
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)

        bubbleBackground.pin(to: bubble)

        bodyLabel.numberOfLines = 0
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.pin(to: bubble, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md
        ))

        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.constrain(in: bubble) { parent in
            // The body text ends with a clear-color twin of the time string
            // (see configure), so anchoring to the body's last baseline drops
            // the visible time exactly into that reserved footprint.
            timeLabel.lastBaselineAnchor.constraint(equalTo: bodyLabel.lastBaselineAnchor)
            timeLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.md)
        }

        contentView.addSubview(bubble)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Metrics.groupSpacing)
        leadingConstraint = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        trailingConstraint = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bubble.widthAnchor.constraint(
                lessThanOrEqualTo: contentView.widthAnchor, multiplier: Metrics.maxWidthFraction
            )
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with model: MessageRowModel) {
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let timeFont = UIFont.preferredFont(forTextStyle: .caption2)

        bubbleBackground.backgroundColor = model.isMine ? .systemBlue : .secondarySystemBackground
        radii = resolvedRadii(for: model)
        bubbleBackground.cornerConfiguration = .corners(
            topLeftRadius: .fixed(radii.topLeft),
            topRightRadius: .fixed(radii.topRight),
            bottomLeftRadius: .fixed(radii.bottomLeft),
            bottomRightRadius: .fixed(radii.bottomRight)
        )

        // Body text plus an invisible reservation of the time's exact width:
        // when the last line has room the time shares it (Telegram's inline
        // tuck), otherwise wrapping gives it its own line — no measurement.
        let text = NSMutableAttributedString(string: model.body, attributes: [
            .font: bodyFont,
            .foregroundColor: model.isMine ? UIColor.white : UIColor.label
        ])
        text.append(NSAttributedString(string: "\u{2002}" + model.timeText, attributes: [
            .font: timeFont,
            .foregroundColor: UIColor.clear
        ]))
        bodyLabel.attributedText = text

        timeLabel.text = model.timeText
        timeLabel.font = timeFont
        timeLabel.textColor = model.isMine ? .white.withAlphaComponent(0.75) : .secondaryLabel

        leadingConstraint.isActive = false
        trailingConstraint.isActive = false
        (model.isMine ? trailingConstraint : leadingConstraint).isActive = true
        topConstraint.constant = switch model.position {
        case .single, .first: Metrics.groupSpacing
        case .middle, .last: Metrics.runSpacing
        }
    }

    /// Telegram grouping: the corners facing same-run neighbors flatten, on
    /// the bubble's aligned side only. Corner configuration is left/right
    /// (not leading/trailing), so resolve the aligned side per direction.
    private func resolvedRadii(for model: MessageRowModel) -> CornerRadii {
        let large = Metrics.cornerRadius
        let small = Metrics.groupedCornerRadius
        let top = (model.position == .middle || model.position == .last) ? small : large
        let bottom = (model.position == .middle || model.position == .first) ? small : large

        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let onRight = model.isMine != isRTL
        return onRight
            ? CornerRadii(topLeft: large, topRight: top, bottomLeft: large, bottomRight: bottom)
            : CornerRadii(topLeft: top, topRight: large, bottomLeft: bottom, bottomRight: large)
    }

    // MARK: - Context-menu lift

    /// The context-menu lift target: the bubble alone, not the cell — the
    /// row is full-width but mostly empty flank, and lifting it would drag a
    /// clear rectangle into the platter. The visible path retraces the
    /// bubble's exact per-run corner geometry so the lift clips nothing and
    /// reveals nothing.
    func bubblePreview() -> UITargetedPreview {
        // Two hard constraints, both learned the expensive way:
        // 1. The preview view's bounds must COINCIDE with `visiblePath`'s
        //    bounds. The platter aligns to the path region but restores the
        //    view — an off-center path (e.g. previewing the full-width
        //    content view clipped to the bubble) permanently displaces the
        //    cell content by (path center − view center) after dismissal.
        // 2. The fill must be SUBVIEW content (`bubbleBackground`), never
        //    the preview view's own background — the platter strips and
        //    repaints that, so it ghosts to bare text mid-flight.
        // `view: bubble` + a bounds-filling path + a content-carried fill
        // satisfy both; the platter needs no compensation color.
        let parameters = UIPreviewParameters()
        parameters.visiblePath = bubblePath()
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: bubble, parameters: parameters)
    }

    /// Whether `point` (cell coordinates) lands on the bubble — the menu's
    /// begin gate, so the empty flank of a row is not a press target.
    func bubbleContains(_ point: CGPoint) -> Bool {
        bubble.bounds.contains(convert(point, to: bubble))
    }

    /// The bubble outline. `UIPreviewParameters.visiblePath` can't read the
    /// layer's `cornerConfiguration`, so the same four radii are retraced as
    /// a bezier path (circular arcs; the platter clips, so the corner-style
    /// difference from the layer's rendering is sub-pixel).
    private func bubblePath() -> UIBezierPath {
        let bounds = bubble.bounds
        let path = UIBezierPath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY + radii.topLeft))
        path.addArc(
            withCenter: CGPoint(x: bounds.minX + radii.topLeft, y: bounds.minY + radii.topLeft),
            radius: radii.topLeft, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true
        )
        path.addLine(to: CGPoint(x: bounds.maxX - radii.topRight, y: bounds.minY))
        path.addArc(
            withCenter: CGPoint(x: bounds.maxX - radii.topRight, y: bounds.minY + radii.topRight),
            radius: radii.topRight, startAngle: 1.5 * .pi, endAngle: 2 * .pi, clockwise: true
        )
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - radii.bottomRight))
        path.addArc(
            withCenter: CGPoint(x: bounds.maxX - radii.bottomRight, y: bounds.maxY - radii.bottomRight),
            radius: radii.bottomRight, startAngle: 0, endAngle: 0.5 * .pi, clockwise: true
        )
        path.addLine(to: CGPoint(x: bounds.minX + radii.bottomLeft, y: bounds.maxY))
        path.addArc(
            withCenter: CGPoint(x: bounds.minX + radii.bottomLeft, y: bounds.maxY - radii.bottomLeft),
            radius: radii.bottomLeft, startAngle: 0.5 * .pi, endAngle: .pi, clockwise: true
        )
        path.close()
        return path
    }
}
