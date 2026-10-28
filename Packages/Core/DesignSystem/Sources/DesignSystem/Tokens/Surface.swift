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

    /// THE skeleton's ground (#1753): one opaque, neutral grey every bone
    /// (`SkeletonBoneView`) wears by default, whatever lies behind it — the
    /// grey of an emote's skeleton, now the same on a page, a card, a banner
    /// or a photo. A translucent fill (`tertiarySystemFill`, as before) took
    /// the colour of its background: grey on a page, black over a banner's
    /// ramp (the owner, 2026-10-27). Visible on both the page and a card, in
    /// light and dark.
    public static let skeleton: UIColor = .systemGray5

    /// The skeleton's ground on a surface that is dark whatever the
    /// appearance (the snap feed's black page): the dark grey of `skeleton`,
    /// in light mode too — a light grey bone read as a hole in the page.
    public static let skeletonOnDark: UIColor = UIColor.systemGray5.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .dark)
    )

    /// THE MEDIA GROUND (#1771): what a picture's place shows when there is no
    /// picture in it — loading (under the bone's sweep, which wears this same
    /// grey), missing, or failed. A media slot's host paints this and nothing
    /// else under its bone, so a tile looks the same waiting or empty, just
    /// without the sweep, and two greys never meet. A host's own CHROME (a
    /// post card's ground around its words) keeps `card`.
    public static let mediaGround: UIColor = skeleton

    /// The media ground on a surface that is dark whatever the appearance
    /// (map pins, the shop's posters, the snap feed): `skeletonOnDark`.
    public static let mediaGroundOnDark: UIColor = skeletonOnDark

    /// A patch of the media ground (#1772): the place of a picture still on
    /// its way where the host draws it as an IMAGE — a list row's, a
    /// button's — and a slot cannot stand. A template: the host tints it
    /// `mediaGround`, so it follows the appearance; a list row rounds it with
    /// its image's corner.
    public static func groundImage(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysTemplate)
    }

    /// The same, round: a face's place.
    public static func groundDisc(diameter: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { context in
            UIColor.black.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        }.withRenderingMode(.alwaysTemplate)
    }

    /// A card's corner (#1494): the For You card's, every card of the app's.
    /// A CARD — a surface that holds content, lighter than its page — not a
    /// thumbnail or a media tile, whose corners are their own.
    public static let cardCornerRadius: CGFloat = 26

    /// Dresses `view` as a card: the card's tone, its corner and its edge —
    /// the one contract every card follows (#1494).
    @MainActor
    public static func dressCard(_ view: UIView) {
        view.backgroundColor = card
        view.layer.cornerRadius = cardCornerRadius
        view.layer.cornerCurve = .continuous
        applyCardEdge(to: view)
    }

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
