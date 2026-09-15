import DesignSystem
import UIKit

/// Which of the chosen media the editor is showing, as a row of dots over the
/// picture.
///
/// ⚠️ **WRITTEN HERE RATHER THAN REUSED, AND THE MEASUREMENT SAYS WHY.**
/// `PostGrid.MediaPageIndicatorView` does this and is tested — but promoting it
/// to DesignSystem means moving ~1590 lines across seven files
/// (`MediaPageIndicatorView`, `PostMetaPillView`, `CarouselPlaybackAudit`,
/// `PostMetricLabel`, `PageScrubber`, `PageWindow`, `MediaDateInk`), because the
/// chip reaches a font helper, an ink vocabulary, a window rule and a DEBUG
/// audit harness. That is PostGrid's chrome layer, not a shared component.
///
/// And the component carries far more than this screen needs: a scrub gesture, a
/// sliding five-dot window with edge fades, and a material it never draws
/// (`makeGround()` returns nil) around a label it never shows. The editor asks
/// one question — which of a handful of pages am I on — so it gets one answer.
/// If a third surface ever needs the full chip, promote THAT, with its cost
/// known in advance.
final class MediaPageDotsView: UIView {
    private enum Metrics {
        static let diameter: CGFloat = 6
        static let spacing: CGFloat = 5
        /// The mark is the same dot at full strength; the rest recede. Opacity
        /// rather than size, so nothing moves as the page changes — a row whose
        /// dots resize under a finger reads as unstable.
        static let restingAlpha: CGFloat = 0.35
    }

    private let row = UIStackView()
    private var dots: [UIView] = []
    private var current = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // ⚠️ **A `CGColor` DOES NOT FOLLOW AN APPEARANCE CHANGE.** The dot's fill
        // is a `UIColor` and re-resolves itself; its HALO is a `layer.shadowColor`,
        // resolved once at the moment it was read. Without this the halo would keep
        // the colour the device had when the screen was built, and a dot switched
        // to dark would carry a dark halo — the one combination that is invisible
        // on both. `MediaFilterRowView`'s chip ring states the same rule.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (dots: MediaPageDotsView, _) in
            dots.restateHaloes()
        }
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Metrics.spacing
        row.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ⚠️ **FEWER THAN TWO PAGES HIDES THE WHOLE ROW.** One dot answers a
    /// question nobody asked and puts furniture over the picture.
    func configure(count: Int, current: Int) {
        isHidden = count < 2
        guard count >= 2 else { return }
        if dots.count != count {
            for dot in dots { dot.removeFromSuperview() }
            dots = (0..<count).map { _ in makeDot() }
            for dot in dots { row.addArrangedSubview(dot) }
        }
        setCurrent(current)
    }

    /// Moves the mark without rebuilding: this is called from the canvas's own
    /// scroll callbacks.
    func setCurrent(_ page: Int) {
        guard !dots.isEmpty else { return }
        current = min(max(page, 0), dots.count - 1)
        for (index, dot) in dots.enumerated() {
            dot.alpha = index == current ? 1 : Metrics.restingAlpha
        }
    }

    /// ⚠️ INK THAT SURVIVES THE PICTURE — AND, SINCE THE EDITOR'S GROUND STARTED
    /// FOLLOWING THE DEVICE, THE GROUND TOO. These sit on media of any brightness,
    /// so a dot carries a halo of the opposite colour; a white dot with a dark halo
    /// was right while the ground was always black, and invisible the moment a
    /// fitted picture left white showing behind it. Semantic ink and a semantic
    /// halo are legible over both.
    private func restateHaloes() {
        for dot in dots { dot.layer.shadowColor = UIColor.systemBackground.cgColor }
    }

    private func makeDot() -> UIView {
        let dot = UIView()
        dot.backgroundColor = .label
        dot.layer.cornerRadius = Metrics.diameter / 2
        dot.layer.shadowColor = UIColor.systemBackground.cgColor
        dot.layer.shadowOffset = .zero
        dot.layer.shadowRadius = 2
        dot.layer.shadowOpacity = 0.45
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Metrics.diameter),
            dot.heightAnchor.constraint(equalToConstant: Metrics.diameter)
        ])
        return dot
    }

    #if DEBUG
    /// Internal for tests: how many dots are drawn, and which one is the mark.
    var debugDotCount: Int { dots.count }
    var debugCurrent: Int { current }
    #endif
}
