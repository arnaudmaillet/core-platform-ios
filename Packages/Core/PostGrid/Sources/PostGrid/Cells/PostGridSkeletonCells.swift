import DesignSystem
import UIKit

// The grid's loading placeholders: shimmering stand-ins that borrow the
// real cells' geometry — same cards, same corners, same margins — so hydration
// swaps content into a frame the eye has already accepted, instead of
// replacing a spinner with a different screen.

// MARK: - Timeline row skeleton

/// The `PostGridListRowCell` mimic: the same soft 18pt card, holding stacked
/// caption lines over the quiet metadata row (counter cluster leading, age
/// trailing). Two- and three-line variants alternate so a column of them
/// reads as text, not as a pattern.
public final class PostGridSkeletonListCell: UICollectionViewCell {
    public static let reuseID = "PostGridSkeletonListCell"

    private let card = PostGridSkeletonCard()

    override public init(frame: CGRect) {
        super.init(frame: frame)
        card.pin(to: contentView)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func configure(variant: Int) {
        card.setLines(variant.isMultiple(of: 2) ? 3 : 2)
    }
}

/// The card body of a timeline-row skeleton, reusable outside a collection
/// view (a first-load screen skeleton stacks these directly).
public final class PostGridSkeletonCard: UIView {
    private let thirdLine = SkeletonBoneView()

    public init() {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        // The shimmer has to be the shape content hydrates INTO — a literal
        // here silently stopped matching the day the card's curve moved.
        layer.cornerRadius = PostGridListRowCell.cardCornerRadius
        layer.cornerCurve = .continuous

        // Caption lines at body-text pitch: 14pt bones on the ~21pt line grid.
        let firstLine = SkeletonBoneView()
        let secondLine = SkeletonBoneView()
        let cluster = SkeletonBoneView()
        let age = SkeletonBoneView()

        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let metaRow = UIStackView(arrangedSubviews: [cluster, spacer, age])
        metaRow.axis = .horizontal
        metaRow.alignment = .center
        // The caption→meta breath of the real card (12pt to text ascent),
        // carried as padding so it survives the third line hiding.
        let metaWrap = UIView()
        metaRow.constrain(in: metaWrap) { parent in
            metaRow.topAnchor.constraint(equalTo: parent.topAnchor, constant: 9)
            metaRow.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            metaRow.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            metaRow.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }

        let column = UIStackView(arrangedSubviews: [firstLine, secondLine, thirdLine, metaWrap])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 7
        column.constrain(in: self) { parent in
            column.topAnchor.constraint(equalTo: parent.topAnchor, constant: 18)
            column.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 16)
            column.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16)
            column.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -18)
        }

        NSLayoutConstraint.activate([
            firstLine.heightAnchor.constraint(equalToConstant: 14),
            firstLine.widthAnchor.constraint(equalTo: column.widthAnchor),
            secondLine.heightAnchor.constraint(equalToConstant: 14),
            secondLine.widthAnchor.constraint(equalTo: column.widthAnchor, multiplier: 0.62),
            thirdLine.heightAnchor.constraint(equalToConstant: 14),
            thirdLine.widthAnchor.constraint(equalTo: column.widthAnchor, multiplier: 0.38),
            metaWrap.widthAnchor.constraint(equalTo: column.widthAnchor),
            cluster.heightAnchor.constraint(equalToConstant: 10),
            cluster.widthAnchor.constraint(equalToConstant: 76),
            age.heightAnchor.constraint(equalToConstant: 10),
            age.widthAnchor.constraint(equalToConstant: 34)
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func setLines(_ count: Int) {
        thirdLine.isHidden = count < 3
    }
}

// MARK: - Mosaic tile skeleton

/// The `PostGridTileCell` mimic: one full-bleed bone with the same rounding the
/// real tile carries. The layout itself supplies the brick shapes, so the
/// skeleton page IS the real pattern.
public final class PostGridSkeletonTileCell: UICollectionViewCell {
    public static let reuseID = "PostGridSkeletonTileCell"

    private let bone = SkeletonBoneView(rounding: .fixed(PostGridTileCell.mosaicCornerRadius))

    /// Tracks the real tile's rounding — see `PostGridTileCell.cornerRadius`.
    ///
    /// Load-bearing for hydration: the skeleton hands off to content through a
    /// cross-dissolve inside the same silhouette, so a skeleton still rounded at
    /// the mosaic's 10pt under a grid whose tiles are 16pt would visibly change
    /// shape at the very moment it is supposed to be invisible.
    public var cornerRadius: CGFloat = PostGridTileCell.mosaicCornerRadius {
        didSet { bone.layer.cornerRadius = cornerRadius }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        bone.pin(to: contentView)
    }

    /// Same rule as the real tile: a recycled cell comes back visible, whatever
    /// a flight left it as.
    override public func prepareForReuse() {
        super.prepareForReuse()
        isHidden = false
        alpha = 1
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
