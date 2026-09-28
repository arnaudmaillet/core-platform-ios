import CoreNavigation
import FeedInterface
import MediaCore
import UIKit

/// The landing of a card-shaped close for a surface that described its ROW
/// with a `TextRevealOrigin` — a profile's gallery, or any other list outside
/// this feature that opens posts through `presentSnapFeedHero`.
///
/// ## Why this exists
///
/// A card close needs somewhere to land, and until now only a SCREEN could be
/// one: the place page conforms to `CardCloseLanding` itself. A profile cannot
/// — it lives in a package this one cannot see, and it already said everything
/// a landing needs in the origin it hands over: the row's rect (re-asked), its
/// stand-in, its concealment, its choreography. So the landing is built from
/// that description rather than asked of the presenter, and the profile gets
/// the close For You's list has always had without a second copy of it.
///
/// ## What it lands on
///
/// The row the origin names, which for a profile is the post that OPENED the
/// feed — the product rule for a list, stated in `ProfileViewController`:
/// a close never re-orders the list under the card. The page the viewer is
/// actually on travels into that row (`RevealPageFit.covering`), exactly as
/// For You's Following list does.
@MainActor
final class RowCardCloseLanding: CardCloseLanding {
    /// Already wrapped with whatever chrome the host composes around it.
    let origin: TextRevealOrigin
    private let pipeline: ImagePipeline?

    init(origin: TextRevealOrigin, pipeline: ImagePipeline?) {
        self.origin = origin
        self.pipeline = pipeline
    }

    /// The window's geometry, or `nil` when the row cannot be found — which is
    /// how the driver selects its plain slide instead of a window closing onto
    /// the middle of the screen.
    ///
    /// ⚠️ Measured in the FEED's space only to ask whether the row exists; the
    /// geometry re-asks the rect in whatever space the transition runs in.
    func cardCloseGeometry(dismissing feed: UIViewController) -> RevealGeometry? {
        guard origin.rowFrame(feed.view) != nil else { return nil }
        return TextRevealInstaller.geometry(feed: feed, origin: origin, pipeline: pipeline)
    }

    /// The row is hidden for the length of the close by the reveal itself and
    /// put back by its completion; this is the backstop for a pop finished by
    /// anything else.
    func clearLandingConcealment() {
        origin.setConcealed(false)
    }
}

extension FeedFeatureBuilder {
    /// What a flight-opened feed's card-shaped close lands on, or `nil` for no
    /// card close at all.
    ///
    /// ⚠️ THE QUESTION USED TO BE "IS THE PRESENTER THE PLACE PAGE?", and every
    /// other surface answered no. A profile opened a media post with a flight
    /// and nothing beside it, so a text page reached by paging had no drag and
    /// a chevron that cut — the defect this replaces.
    ///
    /// In order:
    /// 1. a presenter that is itself a landing keeps its own answer (the place
    ///    page stages its tiles and tabs in ways no origin can describe);
    /// 2. otherwise a presenter that described its ROW lands there, wrapped
    ///    with the host's `dock` choreography;
    /// 3. otherwise nothing — a surface that cannot describe a row gets no
    ///    window, which is what it had before.
    ///
    /// Pure apart from the object it builds, so the choice is testable without
    /// a navigation stack.
    static func cardCloseLanding(
        for presenter: UIViewController,
        origin: SnapFeedHeroOrigin,
        pipeline: ImagePipeline?,
        dock: (TextRevealOrigin) -> TextRevealOrigin
    ) -> (any CardCloseLanding)? {
        if let screen = presenter as? any CardCloseLanding { return screen }
        guard let reveal = origin.textReveal, TextRevealInstaller.isEnabled else { return nil }
        return RowCardCloseLanding(origin: dock(reveal), pipeline: pipeline)
    }
}
