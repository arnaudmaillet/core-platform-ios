import DesignSystem
import UIKit

/// The inbox's unread pill: the count in white on the accent gradient
/// (#1169), "99+" past 99, a circle for one digit and a capsule beyond.
///
/// Worn in two places, the same pill: on a request's avatar (with a ring in
/// the list's own colour, so it reads as sitting ON the face), and under a
/// conversation row's time (#2049, no ring: it sits on the row, not on a
/// face).
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
        /// The ring that separates the badge from a disc beneath it. Drawn in
        /// the list's own background colour, so the badge reads as sitting ON
        /// the avatar rather than being part of it.
        ///
        /// 2.5pt: at 2 the ring disappeared into the disc's own edge at the one
        /// place they cross, which is exactly where it has work to do.
        static let ringWidth: CGFloat = 2.5
    }

    /// The pill's fill: the icon's gradient (#1169).
    private let gradient = CAGradientLayer()
    private let label = UILabel()
    private var width: NSLayoutConstraint!
    private let ringed: Bool

    /// `ringed`: a ring in the list's background colour, for a pill over a
    /// face.
    init(ringed: Bool) {
        self.ringed = ringed
        super.init(frame: .zero)
        gradient.colors = Palette.accentGradient.map { $0.resolvedColor(with: traitCollection).cgColor }
        gradient.startPoint = Palette.accentGradientStart
        gradient.endPoint = Palette.accentGradientEnd
        gradient.cornerCurve = .continuous
        layer.insertSublayer(gradient, at: 0)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        if ringed { layer.borderWidth = Metrics.ringWidth }
        // The gradient's stops follow the appearance and the contrast, and so
        // does the ring: a layer holds CGColors and re-resolves nothing itself.
        applyColours()
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]
        ) { (view: UnreadCountPill, _: UITraitCollection) in
            view.applyColours()
        }

        // `.caption1` rather than `.caption2`: the pill grew, and a number in
        // it should look deliberate rather than lost.
        label.font = UIFont.scaledFont(forTextStyle: .caption1, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        // The same trap `PagedTabBar.BadgeView` documents: a semantic colour
        // can resolve to the wrong end of the spectrum over a tinted fill, so
        // the count's colour is stated outright. White in both appearances:
        // the gradient does not flip with them.
        label.textColor = .white
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
        gradient.frame = bounds
    }

    private func applyColours() {
        gradient.colors = Palette.accentGradient.map { $0.resolvedColor(with: traitCollection).cgColor }
        if ringed { layer.borderColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor }
    }

    /// What the pill reads: "99+" past 99. Pure, for tests.
    static func text(for count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }

    /// The count, nil for a bare dot. Hidden at zero, the same rule
    /// `PagedTabBar` follows.
    func show(count: Int?) {
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

    /// Hides the pill.
    func hide() {
        isHidden = true
    }

    /// The count drawn, nil when hidden or a dot. Tests.
    var shownText: String? { isHidden || label.isHidden ? nil : label.text }
}
