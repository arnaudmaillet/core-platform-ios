import DesignSystem
import UIKit

/// One icon+count pair of a metadata line ("♡ 1.2K"). The icon tracks the
/// label's font size through a symbol configuration, so every register stays
/// optically matched. Hidden whenever the counter has no value — absence, not
/// an asserted zero.
///
/// Three registers now, and the third is the one that means something:
///
/// * **footnote** on a text card's closing line — a quiet readout on the card's
///   own fill.
/// * **caption2 semibold** on a media TILE — two short numbers over a thumbnail
///   nobody presses.
/// * **footnote semibold** on a card's preview chips — sized as CONTROLS, since
///   that is what they are becoming. See `PostMetaPillView.font`.
public final class PostMetricLabel: UIView {
    private let label = UILabel()

    /// - Parameter iconColor: the glyph's colour, defaulting to the text's.
    ///
    ///   ⚠️ Split from `color` so a counter can say WHICH of its two halves is
    ///   the value. The number is the datum and leads; the glyph names it and
    ///   is a label, not data. Drawn in one colour the pair reads as two equal
    ///   marks, and — the reason this appeared — it also made a card's counter
    ///   chips disagree with the band's control pill, which is glyph-only and
    ///   secondary: same capsule, same height, two different inks.
    public init(
        symbol: String, font: UIFont, color: UIColor,
        iconColor: UIColor? = nil, shadowed: Bool = false
    ) {
        super.init(frame: .zero)
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font, scale: .small)
        icon.tintColor = iconColor ?? color
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = font
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true
        // ⚠️ A COUNT MAY NEVER TRUNCATE. "1…" is not a smaller "160", it is a
        // different number, and the reader has no way to tell it was clipped.
        //
        // 999 rather than required so the layout still has one thing left to
        // break at the largest accessibility sizes; everything the preview's
        // chip row is willing to give up sits below it. Measured — at the
        // default label priority the comments count on a four-chip row rendered
        // as "…" and looked deliberate.
        label.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        setContentCompressionResistancePriority(.init(999), for: .horizontal)

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4
        row.pin(to: self)

        if shadowed {
            // Overlay context (media tiles): legibility over any brightness
            // via a soft shadow, never a scrim — the thumbnail stays clean.
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.55
            layer.shadowRadius = 3
            layer.shadowOffset = .zero
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func set(_ value: Int64?) {
        isHidden = value == nil
        label.text = value.map(PostMetadata.count)
    }
}

extension UIFont {
    /// The tile counters' semibold caption2. Internal to the package: the
    /// cells share one measurement so grid and list stay optically matched.
    static func postGridSystemFont(matching font: UIFont, weight: Weight) -> UIFont {
        UIFont.systemFont(ofSize: font.pointSize, weight: weight)
    }
}
