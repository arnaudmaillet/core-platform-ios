import UIKit

/// Hides the part of a page that its CARD has no room for, while a reveal is
/// in flight.
///
/// A collapsed card previews four lines and closes with its metric line; the
/// page shows the whole caption. Measured on an iPhone SE that is 145pt against
/// 299 — so more than the card's own height has no counterpart, and the mask
/// slices straight through it. Two things go wrong at once: the text is cut
/// mid-line for the length of the flight, and the final frame swaps a sentence
/// for the card's `♡ 86 · now`.
///
/// This covers everything below the card's own caption, so the window shows
/// what the card shows and the card's closing line arrives into empty space.
/// It is an OVERLAY rather than a mask: a mask's opacity cannot be faded
/// toward "not masking" — dropping a mask view's alpha hides the content
/// instead of revealing it — whereas an overlay's alpha animates and scrubs
/// like any other view property.
///
/// ```
///   card (145pt)          page, veiled          page, whole
///   ┌───────────────┐     ┌───────────────┐     ┌───────────────┐
///   │ four lines of │     │ four lines of │     │ four lines of │
///   │ the caption…  │     │ the caption…  │     │ the caption…  │
///   │ …Show more    │     │▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│     │ …and the rest │
///   │ ♡ 86     now  │     │               │     │ of it, and    │
///   └───────────────┘     │               │     │ then comments │
///                          the veil            └───────────────┘
/// ```
final class RevealVeilView: UIView {
    /// The dissolve at the top edge, and it is deliberately TINY.
    ///
    /// It was 28pt, and that was the bug the veil existed to prevent. The band
    /// ramps the tint from nothing to solid across its own height, so 28pt of
    /// ramp starting at the cut covered the page's fifth line — a 20.5pt line —
    /// at an average alpha of about a third. Not hidden: greyed, and perfectly
    /// legible, sitting exactly where the card's `♡ 86 · now` was about to
    /// arrive. A whole sentence rode the flight in the metric line's seat.
    ///
    /// So the band is small AND `installRevealVeil` hangs it ABOVE the cut, so
    /// the ramp finishes where the caption ends rather than starting there.
    /// Everything from the cut down is solid, and the dissolve spends itself on
    /// the descender strip of the line above — where the tint matches the
    /// ground it covers and there is nothing to grey.
    ///
    /// ```
    ///          28pt, below the cut          4pt, above it
    ///   line 4  launch, a migration…        launch, a migration…
    ///   cut    ─────────────────────       ─────────────────────
    ///   line 5  silently no-oping…  ← !!   ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
    ///           ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒         ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
    /// ```
    static let fadeBand: CGFloat = 4

    override class var layerClass: AnyClass { CAGradientLayer.self }

    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    init(tint: UIColor) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        apply(tint: tint)
        // `CGColor` does not follow the interface style on its own, so the
        // stops are re-resolved when it changes — the same rule the pin's ring
        // follows.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.apply(tint: self.tint)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var tint: UIColor = .clear

    private func apply(tint: UIColor) {
        self.tint = tint
        let resolved = tint.resolvedColor(with: traitCollection)
        gradient.colors = [
            resolved.withAlphaComponent(0).cgColor,
            resolved.cgColor,
            resolved.cgColor
        ]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The band is a fixed number of POINTS, so its share of the layer has
        // to be recomputed whenever the height changes — a fraction fixed once
        // would stretch the dissolve over the whole page on a tall veil and
        // squash it to nothing on a short one.
        let height = max(bounds.height, 1)
        let stop = min(Self.fadeBand / height, 1)
        gradient.locations = [0, NSNumber(value: Double(stop)), 1]
    }
}
