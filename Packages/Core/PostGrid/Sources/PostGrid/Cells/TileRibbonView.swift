import DesignSystem
import UIKit

/// A mark across a tile's top edge — the shop's "Best value" chip, on a post
/// tile: a short capitalised word (and a glyph) on the points' tint,
/// straddling the edge so it never takes the picture's room (#1280, the
/// sound sheet's "Original").
public final class TileRibbonView: UIView {
    private let label = UILabel()
    private let glyph = UIImageView()
    private let stack = UIStackView()

    override public init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = PointsSymbol.tint
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
        label.font = .scaledSystemFont(ofSize: 9, weight: .bold, relativeTo: .caption2, maximumPointSize: 12)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        glyph.tintColor = .white
        glyph.contentMode = .scaleAspectFit
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: .scaledSystemFont(ofSize: 8, weight: .bold, relativeTo: .caption2, maximumPointSize: 11)
        )
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The word, capitalised as the shop's chips are, and an optional glyph.
    public func set(title: String, symbolName: String?) {
        label.text = title.uppercased()
        glyph.image = symbolName.flatMap { UIImage(systemName: $0) }
        glyph.isHidden = glyph.image == nil
        accessibilityLabel = title
    }

    /// How far above the tile's top edge the chip reaches: half its height —
    /// what a host must leave clear (a row's inset) so it is not clipped.
    public static var overhang: CGFloat {
        let font = UIFont.scaledSystemFont(ofSize: 9, weight: .bold, relativeTo: .caption2, maximumPointSize: 12)
        return (font.lineHeight + 6) / 2
    }
}
