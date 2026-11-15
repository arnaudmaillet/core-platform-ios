import CoreModels
import FeedInterface
import MediaCore
import PostGrid
import UIKit

/// How For You's two rows describe themselves to the shared flight
/// (`presentSnapFeedHero`): a friend's FACE. A shelf's CARD is
/// `PostShelfOrigins`'.
///
/// Built here rather than inline in `ForYouViewController` so the one
/// decision the rows kept getting wrong — what a close has to work with — is
/// something a test can hold without a navigation stack.
///
/// ## ⚠️ Every origin carries its window, whatever the tapped post is
///
/// A row opens a MEDIA post with a flight and a TEXT post as a window, and for
/// the opening that choice is right. It is not the whole of the close. The
/// feed is a pager: open a photograph, page onto a text post, and there is
/// nothing left to fly — both zoom grabs refuse a `.card` page before they
/// look at an axis, the flight's animator declines the chevron's pop, and the
/// only driver that closes a card, `RowCardCloseLanding`, is armed ONLY for an
/// origin with a `textReveal`. The rows offered one for text posts only, so
/// the grab did nothing and the chevron's hero failed. Filmed on a Following
/// media card paged onto a text post. The profile learnt the same lesson
/// (`ProfileViewController`'s "Offered for EVERY post, not only text ones").
///
/// `hasHero` still decides the OPENING; the reveal only adds the close.
///
/// ## ⚠️ A close stages the page before it measures the row
///
/// The rows are the LIST's leading header, so they move with it — and the pop
/// animates the safe area this list adds to its inset, so an unpinned list
/// drifts under a close that has already measured where it lands. Every other
/// close on this screen pins the inset first (`beginHeroFreeze`); the rows did
/// not, and their cards landed beside the item they left from. Both the
/// flight's staging and the window's pin it, bring the item back into its
/// row's view, and hand the inset back when the close is over.
@MainActor
enum ForYouRowOrigins {
    /// What every close from a row does before it reads a rect: pin the list's
    /// inset, then bring the item back into its row's view — the list VC's own
    /// order (`ForYouPostListViewController.textRowReveal`). `then` runs once
    /// both are done — the moment the close is about to measure.
    /// A window's row rect: the item where it is, or — only when it has
    /// scrolled out of its row — where bringing it back puts it.
    ///
    /// ⚠️ ASKED BEFORE `willStageDismissal`. `RowCardCloseLanding` checks that
    /// the row exists before it builds the geometry whose staging would bring
    /// the item back, so an item the viewer scrolled away under the open post
    /// read as "no row" and the close fell to a plain slide. Moving the row
    /// only when the item is out of it keeps the opening — asked while the
    /// item is under the finger — from nudging a peeking card.
    static func inView(_ current: CGRect?, bringingBack: () -> CGRect?) -> CGRect? {
        current ?? bringingBack()
    }

    static func stageClose(
        page: ForYouGridPage?, then staged: () -> Void, bringIntoView: () -> Void
    ) {
        page?.beginHeroFreeze()
        bringIntoView()
        staged()
    }
}
