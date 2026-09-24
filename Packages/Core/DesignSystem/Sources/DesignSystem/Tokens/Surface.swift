import UIKit

/// The three tones a screen of cards is made of, in one place.
///
/// ```
///   light                          dark
///   ┌──────────────────────────┐   ┌──────────────────────────┐
///   │ page   F2F2F7            │   │ page   000000            │
///   │  ┌────────────────────┐  │   │  ┌────────────────────┐  │
///   │  │ card  FFFFFF       │  │   │  │ card  1C1C1E  edge │  │
///   │  │  ▢ pill  tert.fill │  │   │  │  ▢ pill  tert.fill │  │
///   │  └────────────────────┘  │   │  └────────────────────┘  │
///   └──────────────────────────┘   └──────────────────────────┘
/// ```
///
/// ⚠️ **THE CARD IS LIGHTER THAN THE PAGE, AND THAT IS THE ELEVATION.** In
/// light appearance a lighter surface reads as closer; a white card on the
/// grey page is raised by tone alone, which is how Settings, the App Store
/// and this app's own sign-in screen do it. There is deliberately NO resting
/// shadow: it would encode the same fact twice, it is invisible in the dark
/// (so the two appearances would stop being one design), and a column of
/// shadowed cards is a column of offscreen passes. Depth is spent where it
/// says something — a press (`PressFeedback`) and a lifted preview.
///
/// ⚠️ **THE DARK SIDE GETS AN EDGE INSTEAD.** Tone alone barely separates
/// 1C1C1E from black, so a card wears a one-pixel `separator` hairline there
/// and nothing at all in the light, where the tone step is plenty. The colour
/// is dynamic and resolves to clear in the light, so a card sets its border
/// once and re-resolves on a style flip rather than branching.
///
/// These are the system's GROUPED tokens, not bespoke colours: they track
/// elevation (a sheet's dark card lightens a step) and accessibility settings
/// for free, and in the dark they are byte-identical to the plain
/// `systemBackground` pair, which is why moving to them changed nothing there.
public enum Surface {
    /// What a screen of cards lies on.
    public static let page: UIColor = .systemGroupedBackground

    /// A card, one step up from the page. Also the ground a media carousel's
    /// gutter shows and the floor a skeleton shimmers on, because they are
    /// the card.
    public static let card: UIColor = .secondarySystemGroupedBackground

    /// The card's outline: `separator` in the dark, clear in the light.
    public static let cardEdge = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.separator.resolvedColor(with: traits)
            : .clear
    }

    /// One device pixel, whatever the screen's scale — the width a separator
    /// is drawn at, so the card's edge and a table's rule are the same line.
    public static func hairline(for traits: UITraitCollection) -> CGFloat {
        1 / max(traits.displayScale, 1)
    }

    /// Dresses a card's layer in its edge and keeps it dressed across style
    /// and scale changes. Call once from the owner's initialiser; the owner
    /// stays free of trait bookkeeping.
    ///
    /// The handler reads the view UIKit hands it rather than capturing the
    /// argument: a registration lives on the view, so a closure that held the
    /// view would hold it forever.
    @MainActor
    public static func applyCardEdge(to view: UIView) {
        resolveCardEdge(on: view)
        view.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: UIView, _) in
            resolveCardEdge(on: view)
        }
    }

    @MainActor
    private static func resolveCardEdge(on view: UIView) {
        view.layer.borderWidth = hairline(for: view.traitCollection)
        view.layer.borderColor = cardEdge.resolvedColor(with: view.traitCollection).cgColor
    }
}
