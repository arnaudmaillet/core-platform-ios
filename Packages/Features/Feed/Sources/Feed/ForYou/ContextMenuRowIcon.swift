import DesignSystem
import UIKit

/// The leading half of a mode row in the context menu: a count pill followed by
/// the mode's glyph, drawn as one image.
///
/// ⚠️ **A `UIMenu` row is not a view you can lay out.** It has a title, an
/// optional subtitle and one leading image, and nothing else — no accessory, no
/// custom cell, no attributed title. So a row that has to read
/// `[8] [briefcase] Work` can only get its first two elements by drawing them
/// into the one image slot it does have. That is what this is: not decoration,
/// but the only place a badge can go.
///
/// **Every row reserves the pill's width whether or not it has a pill**, so the
/// glyphs line up in a column and the labels start at the same x. A menu whose
/// icons shift left and right depending on which modes happen to have activity
/// is harder to read than one with a gap in it.
///
/// **Zero draws no pill.** A red `0` is a notification badge claiming there is
/// nothing to notify — it reads as activity at a glance and then contradicts
/// itself, which is worse than the ambiguity it was meant to remove. The
/// reserved gap says "counted, nothing waiting" without shouting it.
enum ContextMenuRowIcon {
    private enum Metrics {
        /// Tall enough for two digits at the menu's own type size, short enough
        /// not to set the row height itself.
        static let pillHeight: CGFloat = 18
        /// The pill's minimum width — a single digit sits in a circle rather
        /// than a squashed capsule.
        static let pillMinWidth: CGFloat = 18
        static let pillTextInset: CGFloat = 6
        static let glyphSize: CGFloat = 17
        /// Between the pill and the glyph.
        static let gap: CGFloat = Spacing.sm
        /// ⚠️ **Monospaced digits, and the reserved width depends on it.** With
        /// proportional digits a "7" is narrower than a "0", so the space held
        /// for a zero-count row did not match the pill an adjacent row actually
        /// drew and the glyph column came out ragged by a point. Tabular digits
        /// make width a function of how MANY digits there are and nothing else —
        /// which is also what stops a pill twitching as a count ticks 7 → 8.
        static let font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    }

    /// `count` of zero reserves the pill's space and draws nothing in it.
    ///
    /// `traits` resolves the dynamic colours: the menu is rebuilt on every
    /// presentation (see `ForYouViewController.makeContextMenu`), so the image
    /// is always drawn for the appearance it is about to appear in — a
    /// `.alwaysOriginal` image would otherwise keep whatever colours it was
    /// baked with when the theme changed underneath it.
    static func image(count: Int, symbol: String, traits: UITraitCollection) -> UIImage? {
        let glyph = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.glyphSize, weight: .regular)
        )?.withTintColor(.label, renderingMode: .alwaysOriginal)

        let pillWidth = pillWidth(for: count)
        let size = CGSize(
            width: pillWidth + Metrics.gap + (glyph?.size.width ?? Metrics.glyphSize),
            height: max(Metrics.pillHeight, glyph?.size.height ?? 0)
        )
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            traits.performAsCurrent {
                if count > 0 {
                    drawPill(count, in: CGRect(
                        x: 0, y: (size.height - Metrics.pillHeight) / 2,
                        width: pillWidth, height: Metrics.pillHeight
                    ), context: context.cgContext)
                }
                glyph?.draw(at: CGPoint(
                    x: pillWidth + Metrics.gap,
                    y: (size.height - (glyph?.size.height ?? 0)) / 2
                ))
            }
        }
        .withRenderingMode(.alwaysOriginal)
    }

    /// Reserved for every row, sized by the WIDEST count in the menu so one
    /// three-digit mode cannot shunt the other four's glyphs out of line.
    /// Callers pass their own count; the width only grows with digits.
    private static func pillWidth(for count: Int) -> CGFloat {
        let text = String(max(count, 0))
        let width = (text as NSString).size(withAttributes: [.font: Metrics.font]).width
        return max(Metrics.pillMinWidth, width + Metrics.pillTextInset * 2)
    }

    private static func drawPill(_ count: Int, in rect: CGRect, context: CGContext) {
        context.setFillColor(UIColor.systemRed.cgColor)
        UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).fill()
        let text = String(count) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Metrics.font,
            .foregroundColor: UIColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }
}
