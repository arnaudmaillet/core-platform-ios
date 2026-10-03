/// WHO CARRIES A CLOSE: the hero (a picture flown between two places that both
/// have it) or the card-shaped close (a whole page carried into its row).
///
/// ⚠️ ONE RULE, ASKED FROM SIX PLACES, AND IT USED TO BE WRITTEN IN EACH.
/// The zoom grab's begin gate, the chevron's pop, the scripted grab, the slide
/// driver's begin gate, its forwarding of a `.hero` pop and its staging of a
/// card (`closeCarriesCard`) all asked "is this the hero's close?", each in
/// its own words. They agreed only because nobody had changed one of them
/// yet: the landing's vote reached the grabs and not the chevron (fixed in the
/// hero push audit, 1.11), and an axis claim reached the slide's begin gate
/// but was asked about the wrong axis on its forwarding branch.
///
/// The hero carries a close when ALL of these hold:
/// - the post on screen has a picture to fly (`zoomDismissalKind == .hero`;
///   a screen that is not a destination at all has nothing to fly);
/// - the row it lands on can receive a picture (`zoomLandingAcceptsHero`);
/// - the host has not given this drag's axis to the card close
///   (`heroClaimsAxis`).
///
/// A missing answer (`nil`) is "no objection": only an explicit `false`
/// refuses. Pure, so the arbitration is a table rather than a story.
public enum DismissalArbiter {
    public static func heroCarries(
        kind: ZoomDismissalKind?,
        landingAcceptsHero: Bool? = nil,
        heroClaimsAxis: Bool? = nil
    ) -> Bool {
        kind == .hero && landingAcceptsHero != false && heroClaimsAxis != false
    }
}
