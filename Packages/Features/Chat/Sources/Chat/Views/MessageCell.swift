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

    private let bubble = UIView()
    private let bodyLabel = UILabel()
    private let timeLabel = UILabel()

    private var topConstraint: NSLayoutConstraint!
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)

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

        bubble.backgroundColor = model.isMine ? .systemBlue : .secondarySystemBackground
        bubble.cornerConfiguration = cornerConfiguration(for: model)

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
    private func cornerConfiguration(for model: MessageRowModel) -> UICornerConfiguration {
        let large = UICornerRadius.fixed(Metrics.cornerRadius)
        let small = UICornerRadius.fixed(Metrics.groupedCornerRadius)
        let top = (model.position == .middle || model.position == .last) ? small : large
        let bottom = (model.position == .middle || model.position == .first) ? small : large

        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let onRight = model.isMine != isRTL
        return onRight
            ? .corners(topLeftRadius: large, topRightRadius: top, bottomLeftRadius: large, bottomRightRadius: bottom)
            : .corners(topLeftRadius: top, topRightRadius: large, bottomLeftRadius: bottom, bottomRightRadius: large)
    }
}
