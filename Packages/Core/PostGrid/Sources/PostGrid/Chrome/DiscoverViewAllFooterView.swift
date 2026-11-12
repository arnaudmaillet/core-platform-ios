import DesignSystem
import UIKit

/// "View all ›" under each of Discover's mosaic chunks: pushes the whole
/// mosaic — For You's `DiscoverGalleryViewController`, a profile's media
/// gallery (#631). In PostGrid since the profile lays out the same list
/// (`DiscoverListLayout`).
///
/// A plain secondary-label button in semibold subheadline, the chevron
/// trailing and pointing RIGHT because it pushes a screen.
///
/// Under the chunk rather than over it: the chunk is content, not a section
/// that needs a title to be understood, and the control belongs where the
/// eye arrives having looked through it. (The sound sheet's sections carry
/// a bare chevron after their title instead, `SectionTitleView`:
/// a row scrolls sideways, and there the head is where the eye starts.)
///
/// **Right-aligned, under the tiles** (2026-09-29; the gaps #2342): the
/// chevron ends on the chunk's right edge, where a row header's "›" ends.
/// The footer is laid flush against the chunk's foot
/// (`DiscoverListLayout.viewAllHeight`) and is exactly what its two gaps and
/// the next post's line need: the words' top `titleTopInset` (12pt) under
/// the tiles, their foot `gapBelowTitle` (16pt) over the next post's line —
/// closer to their tiles than to the next post, so they still read as the
/// mosaic's end. (It was 6pt to the title's line box in a 44pt footer, 8pt
/// and 19pt to the eye: the words looked stuck to the tiles once #2289 drew
/// a full-width line between posts.)
///
/// ⚠️ THE TARGET IS NOT THE FOOTER. At the default text size the footer is
/// about 42pt; the control keeps a 44pt hit target by reaching UP over the
/// chunk's foot (`minimumTargetHeight`), never further past the line into
/// the next post. The footer is laid over the tiles (`zIndex` 1) and takes
/// touches in that overhang (`point(inside:with:)`).
public final class DiscoverViewAllFooterView: UICollectionReusableView {
    public static let reuseID = "DiscoverViewAllFooterView"
    public static let title = "View all"
    /// From the chunk's foot to the top of the words — their CAP line, the
    /// top of "V", which is what the eye measures (#2342). The title's line
    /// box starts higher by the font's ascender less its cap height
    /// (`titleLineTop(font:)`).
    public static let titleTopInset: CGFloat = 12
    /// From the words' foot — their BASELINE: "View all" has no descender —
    /// to the next post's line, which that post's row draws half the rows'
    /// gap (`PostGridListRowCell.separatorOffset`) over its head (#2342).
    public static let gapBelowTitle: CGFloat = 16
    /// The control's least height: a hit target's 44pt, whatever the footer.
    public static let minimumTargetHeight: CGFloat = 44
    /// What VoiceOver says the control does. For You's by default; a host
    /// whose mosaic is something else says so (the profile's is its media).
    public static let defaultAccessibilityHint = "Shows every post in Discover's mosaic"

    /// The title's font: semibold subheadline at the app's text size.
    public static func titleFont() -> UIFont {
        UIFont.scaledFont(forTextStyle: .subheadline, weight: .semibold)
    }

    /// The footer's height at `displayScale`: the gap over the words, the
    /// words from cap line to baseline, the gap under them, and the half of
    /// the rows' gap the next row's line stands over its head — rounded UP
    /// to the pixel grid, so neither gap comes out short.
    public static func preferredHeight(displayScale: CGFloat) -> CGFloat {
        let font = titleFont()
        let height = titleTopInset + font.capHeight + gapBelowTitle + PostGridListRowCell.separatorOffset
        let scale = max(displayScale, 1)
        return (height * scale).rounded(.up) / scale
    }

    /// Where the title's line box starts under the footer's top so that its
    /// cap line stands `titleTopInset` down: a label draws its first
    /// baseline `ascender` under its top.
    static func titleLineTop(font: UIFont) -> CGFloat {
        titleTopInset - (font.ascender - font.capHeight)
    }

    public var onTap: (() -> Void)?

    /// VoiceOver's hint — see `defaultAccessibilityHint`.
    public var controlAccessibilityHint: String? {
        get { button.accessibilityHint }
        set { button.accessibilityHint = newValue }
    }

    private let button = UIButton(configuration: .plain())
    /// The font and the control's top inset the configuration was built
    /// with — rebuilt only when either changes.
    private var applied: (fontSize: CGFloat, top: CGFloat)?

    override public init(frame: CGRect) {
        super.init(frame: frame)
        button.contentHorizontalAlignment = .trailing
        button.contentVerticalAlignment = .top
        button.accessibilityHint = Self.defaultAccessibilityHint
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
        addSubview(button)
        let font = Self.titleFont()
        applyConfiguration(font: font, top: Self.titleLineTop(font: font))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyConfiguration(font: UIFont, top: CGFloat) {
        applied = (font.pointSize, top)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 12, weight: .bold)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = Spacing.xs + 2
        configuration.baseForegroundColor = .secondaryLabel
        // No trailing inset, so the chevron ends on the chunk's edge; a
        // leading one, so the target reaches a little past the words' start.
        // The top one stands the words' cap line `titleTopInset` under the
        // chunk's foot, from wherever the control's top is.
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: top, leading: Spacing.md, bottom: 0, trailing: 0
        )
        var text = AttributedString(Self.title)
        text.font = font
        configuration.attributedTitle = text
        button.configuration = configuration
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        // The control is at least `minimumTargetHeight` tall: what the
        // footer lacks, it takes ABOVE the footer, over the chunk's foot.
        let overhang = max(0, Self.minimumTargetHeight - bounds.height)
        let font = Self.titleFont()
        let top = overhang + Self.titleLineTop(font: font)
        if applied?.fontSize != font.pointSize || applied?.top != top {
            applyConfiguration(font: font, top: top)
        }
        let height = bounds.height + overhang
        let width = min(bounds.width, button.sizeThatFits(CGSize(width: bounds.width, height: height)).width)
        button.frame = CGRect(x: bounds.maxX - width, y: -overhang, width: width, height: height)
    }

    /// The overhang over the chunk's foot is the control's too.
    override public func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || (!button.isHidden && button.frame.contains(point))
    }

    override public func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
        button.accessibilityHint = Self.defaultAccessibilityHint
    }

    /// Presses the control, as a tap would.
    public func sendTap() { onTap?() }

    #if DEBUG
    /// The control's frame — its hit target — in this view's space.
    public var debugControlFrame: CGRect { button.frame }
    /// Its title's frame, in this view's space.
    public var debugTitleFrame: CGRect? {
        button.titleLabel.map { $0.convert($0.bounds, to: self) }
    }
    /// The words' cap line and baseline as drawn, in this view's space: the
    /// title label's top plus its font's metrics.
    public var debugTitleLines: (capTop: CGFloat, baseline: CGFloat)? {
        guard let label = button.titleLabel, let font = label.font else { return nil }
        let top = label.convert(label.bounds, to: self).minY
        return (top + font.ascender - font.capHeight, top + font.ascender)
    }
    #endif
}
