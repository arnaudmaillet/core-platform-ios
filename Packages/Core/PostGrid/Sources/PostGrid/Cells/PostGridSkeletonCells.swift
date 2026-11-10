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

    /// `listStyle` (#2243): the card's bones, or a flat row's — no card,
    /// the row's own column, and the hairline a flat row draws under it.
    public func configure(variant: Int, listStyle: PostListStyle = .cards) {
        card.setLines(variant.isMultiple(of: 2) ? 3 : 2)
        card.listStyle = listStyle
    }
}

/// The card body of a timeline-row skeleton, reusable outside a collection
/// view (a first-load screen skeleton stacks these directly).
public final class PostGridSkeletonCard: UIView {
    private let thirdLine = SkeletonBoneView()

    /// The card, or a flat row's bones (#2243) — the shape the rows of
    /// either style hydrate into.
    public var listStyle: PostListStyle = .cards {
        didSet {
            guard listStyle != oldValue else { return }
            dress()
        }
    }

    private var columnLeading: NSLayoutConstraint!
    private var columnTrailing: NSLayoutConstraint!
    /// A flat row's hairline, inset to its column, mid-gap under it.
    private let rule = UIView()

    public init() {
        super.init(frame: .zero)
        // The shimmer has to be the shape content hydrates INTO — a literal
        // here silently stopped matching the day the card's curve moved.
        layer.cornerCurve = .continuous
        // …and the edge, for the same reason: `dress`, re-run on a style flip.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) {
            (card: PostGridSkeletonCard, _: UITraitCollection) in
            card.dress()
        }
        rule.backgroundColor = .separator
        rule.isHidden = true
        addSubview(rule)

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
        let columnLeading = column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        let columnTrailing = column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        self.columnLeading = columnLeading
        self.columnTrailing = columnTrailing
        column.constrain(in: self) { parent in
            column.topAnchor.constraint(equalTo: parent.topAnchor, constant: 18)
            columnLeading
            columnTrailing
            column.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -18)
        }
        dress()

        NSLayoutConstraint.activate([
            firstLine.heightAnchor.constraint(equalToConstant: 14),
            firstLine.widthAnchor.constraint(equalTo: column.widthAnchor),
            secondLine.heightAnchor.constraint(equalToConstant: 14),
            // The shared width rule (#1774): a body line, then a short one.
            secondLine.widthAnchor.constraint(
                equalTo: column.widthAnchor, multiplier: SkeletonLineWidths.fraction(SkeletonLineWidths.body, at: 1)
            ),
            thirdLine.heightAnchor.constraint(equalToConstant: 14),
            thirdLine.widthAnchor.constraint(
                equalTo: column.widthAnchor, multiplier: SkeletonLineWidths.fraction(SkeletonLineWidths.title, at: 1)
            ),
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

    /// The card's tone, corner and edge, or none of them on a flat row —
    /// whose bones then stand on the row's caption column (#2243).
    private func dress() {
        let flat = listStyle == .flat
        backgroundColor = flat ? .clear : PostGridListRowCell.cardFillColor
        layer.cornerRadius = flat ? .zero : PostGridListRowCell.cardCornerRadius
        layer.borderWidth = flat ? .zero : Surface.hairline(for: traitCollection)
        layer.borderColor = Surface.cardEdge.resolvedColor(with: traitCollection).cgColor
        let side = flat ? PostGridListRowCell.captionInset : 16
        columnLeading?.constant = side
        columnTrailing?.constant = -side
        rule.isHidden = !flat
        setNeedsLayout()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let hairline = Surface.hairline(for: traitCollection)
        let leading = PostGridListRowCell.captionInset
        rule.frame = CGRect(
            x: leading, y: bounds.height + PostGridListRowCell.flatSeparatorOffset - hairline / 2,
            width: max(0, bounds.width + PostGridListLayout.flatRowInset - leading), height: hairline
        )
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
