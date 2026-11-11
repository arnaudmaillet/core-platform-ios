import DesignSystem
import UIKit

/// The inbox's unread pill: "99+" past 99, a circle for one digit and a
/// capsule beyond, in one of two inks (#2292, the owner 2026-11-11):
/// - **primary** — the count in white on the solid unread mark (#2062,
///   never a gradient): a conversation new since the visit, not muted;
/// - **neutral** — the count in `label` on a neutral grey
///   (`neutralFill`): every other unread conversation, waiting, or muted.
///
/// Same shape, size and place in both inks: only the colour says which.
///
/// Worn on the rows, never on a face: under a conversation row's time
/// (#2049), and under a request's Accept and ✕ (#2088). The ringed variant
/// that sat on a request's avatar went with that badge.
final class UnreadCountPill: UIView {
    enum Metrics {
        /// The pill's height, and the diameter a bare dot draws at.
        ///
        /// 20pt against a 48pt disc. It was 14, which is the right size for a
        /// DOT and too small for a number: at 14 the digits had 1.5pt of air
        /// above and below them and the pill read as a smudge with something in
        /// it. The badge is a thing to be READ now, so it is sized to be read.
        static let height: CGFloat = 20
        /// Clearance between the digits and the pill's end caps.
        ///
        /// Generous on purpose: this is what turns a two-digit count into a
        /// capsule rather than a circle with the number wedged into it. A
        /// single digit never reaches it — the height floor wins, so one digit
        /// is a circle — and it only ever describes how a count GROWS. 7 put a
        /// one-digit pill at 22 against a 20pt height, which is neither a
        /// circle nor obviously a capsule; 6 lets the floor bind.
        static let labelInset: CGFloat = 6
    }

    /// The neutral ink's fill (#2292): `systemGray4`, and `systemGray3`
    /// with Increased Contrast — a deeper grey. Opaque, so a pinned row's
    /// band does not tint it. Under `label` it measures 13.8:1 in light and
    /// 11.4:1 in dark (9.5:1 and 7.6:1 with Increased Contrast, where the
    /// pill itself stands further off the row); the WCAG floor is 4.5:1.
    /// `systemGray` under white, the other candidate, is 3.3:1 and fails.
    static let neutralFill = UIColor { traits in
        let grey: UIColor = traits.accessibilityContrast == .high ? .systemGray3 : .systemGray4
        return grey.resolvedColor(with: traits)
    }

    /// The neutral ink's count: the text colour, black in light and white in
    /// dark — the grey flips with the appearance, so its count does too.
    static let neutralText: UIColor = .label

    /// The primary ink's count: white in both appearances. The same trap
    /// `PagedTabBar.BadgeView` documents: a semantic colour can resolve to
    /// the wrong end of the spectrum over a tinted fill, so it is stated
    /// outright — the fill does not flip with the appearance.
    static let primaryText: UIColor = .white

    private let label = UILabel()
    private var width: NSLayoutConstraint!
    /// The ink on show. Tests.
    private(set) var ink: ConversationDisplayModel.UnreadInk = .primary

    init() {
        super.init(frame: .zero)
        // The solid unread mark, as every pill and badge (#2062), until a
        // count says which ink it wears.
        backgroundColor = Palette.counter
        clipsToBounds = true
        layer.cornerCurve = .continuous

        // `.caption1` rather than `.caption2`: the pill grew, and a number in
        // it should look deliberate rather than lost.
        label.font = UIFont.scaledFont(forTextStyle: .caption1, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.textColor = Self.primaryText
        label.isHidden = true
        label.pin(to: self, insets: NSDirectionalEdgeInsets(
            top: 0, leading: Metrics.labelInset, bottom: 0, trailing: Metrics.labelInset
        ))
        heightAnchor.constraint(equalToConstant: Metrics.height).isActive = true
        // Held, because a count re-states it: the pill widens for two digits
        // and returns to a circle for one.
        width = widthAnchor.constraint(equalToConstant: Metrics.height)
        width.isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    /// What the pill reads: "99+" past 99. Pure, for tests.
    static func text(for count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }

    /// The count, nil for a bare dot, in `ink`. Hidden at zero, the same
    /// rule `PagedTabBar` follows.
    func show(count: Int?, ink: ConversationDisplayModel.UnreadInk = .primary) {
        apply(ink)
        guard let count else {
            label.isHidden = true
            width.constant = Metrics.height
            isHidden = false
            return
        }
        isHidden = count <= 0
        label.isHidden = false
        label.text = Self.text(for: count)
        // Never narrower than it is tall — below that a capsule's own corner
        // radius exceeds half its width and the shape degenerates, the same
        // floor the tab capsule's lens and badge both state. So a single digit
        // is a circle, and every digit after it widens the pill by exactly what
        // that digit measures.
        let measured = ceil(((label.text ?? "") as NSString).size(withAttributes: [.font: label.font as Any]).width)
        width.constant = max(Metrics.height, measured + Metrics.labelInset * 2)
    }

    /// The fill and the count's colour for `ink`.
    private func apply(_ ink: ConversationDisplayModel.UnreadInk) {
        self.ink = ink
        switch ink {
        case .primary:
            backgroundColor = Palette.counter
            label.textColor = Self.primaryText
        case .neutral:
            backgroundColor = Self.neutralFill
            label.textColor = Self.neutralText
        }
    }

    /// The count's colour on show. Tests.
    var textColor: UIColor? { label.textColor }

    /// Hides the pill.
    func hide() {
        isHidden = true
    }

    /// The count drawn, nil when hidden or a dot. Tests.
    var shownText: String? { isHidden || label.isHidden ? nil : label.text }
}
