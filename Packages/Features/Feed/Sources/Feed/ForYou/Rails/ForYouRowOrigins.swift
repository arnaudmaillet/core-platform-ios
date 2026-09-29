import CoreModels
import FeedInterface
import PostGrid
import UIKit

/// How For You's two rows describe themselves to the shared flight
/// (`presentSnapFeedHero`): a friend's FACE, or a Following CARD.
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
    /// A friend's story: their posts, flown out of their face.
    ///
    /// `nil` for a friend with nothing to open.
    static func story(
        _ story: ForYouViewModel.FriendStory,
        rails: ForYouRailsView,
        page: ForYouGridPage,
        host: UIView,
        pagePicture: UIImage?,
        closeStaged: @escaping () -> Void = {}
    ) -> SnapFeedHeroOrigin? {
        guard let first = story.posts.first else { return nil }
        let author = story.authorID
        let face = rails.storyFace(for: author)
        let hasMedia = first.kind != .text
        return SnapFeedHeroOrigin(
            post: first,
            stream: story.posts,
            hasHero: hasMedia && rails.storyFrame(for: author, in: host) != nil,
            cover: face,
            style: .listMedia,
            frame: { [weak rails] space in rails?.storyFrame(for: author, in: space) },
            isOnScreen: { [weak rails] in rails?.isStoryOnScreen(author) ?? false },
            setConcealed: { [weak rails, weak page] concealed in
                rails?.setStoryConcealed(concealed, for: author)
                // The flight's close is over once its source is put back.
                if !concealed { page?.endHeroFreeze() }
            },
            depthView: { [weak page] in page },
            // EVERY story — a text first post opens through it, and a media
            // one closes through it once the viewer pages onto words.
            textReveal: storyReveal(
                for: author, face: face, rails: rails, page: page, closeStaged: closeStaged
            ),
            cornerRadius: ForYouStoryCell.Metrics.avatarDiameter / 2,
            // The post's own picture, if the pipeline has it: the far end of
            // the cross-dissolve. Without it the face grows into the page and
            // the page takes over at the landing — still the right motion.
            pagePicture: pagePicture,
            willStageDismissal: { [weak rails, weak page] in
                stageClose(page: page, then: closeStaged) { rails?.bringStoryIntoView(author) }
            }
        )
    }

    /// The window a story opens and closes through: the map marker's text-post
    /// window, out of a disc. Nothing to align (a face has no caption), the
    /// page covering the window whatever its shape, the face as the stand-in
    /// at both ends — whatever post the viewer ended on.
    static func storyReveal(
        for author: ProfileID,
        face: UIImage?,
        rails: ForYouRailsView,
        page: ForYouGridPage,
        closeStaged: @escaping () -> Void = {}
    ) -> TextRevealOrigin {
        let radius = ForYouStoryCell.Metrics.avatarDiameter / 2
        func standIn() -> UIView? {
            guard let face else { return nil }
            let view = UIImageView(image: face)
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.layer.cornerRadius = radius
            return view
        }
        return TextRevealOrigin(
            rowFrame: { [weak rails] space in rails?.storyFrame(for: author, in: space) },
            captionEnd: nil,
            depthView: { [weak page] in page },
            makeDismissStandIn: { _ in standIn() },
            makePresentStandIn: { standIn() },
            alignsPageToSource: false,
            pageFit: .covering,
            cornerRadius: radius,
            fill: nil,
            setConcealed: { [weak rails] concealed in
                rails?.setStoryConcealed(concealed, for: author)
            },
            willStageDismissal: { [weak rails, weak page] _ in
                stageClose(page: page, then: closeStaged) { rails?.bringStoryIntoView(author) }
            },
            // Both ways: a close that sprang back is over too, and the list
            // under a page that is staying has nothing to hold still for.
            dismissalDidEnd: { [weak page] _ in page?.endHeroFreeze() }
        )
    }

    /// A Following card: the row's posts from it on, flown out of the card — a
    /// list row's media flight (`.listMedia`, the card's own corner), wearing
    /// the card's caption as furniture that fades as it grows.
    static func card(
        _ tapped: GalleryPost,
        stream: [GalleryPost],
        rails: ForYouRailsView,
        page: ForYouGridPage,
        host: UIView,
        closeStaged: @escaping () -> Void = {}
    ) -> SnapFeedHeroOrigin {
        let id = tapped.id
        let hasMedia = tapped.kind != .text
        let cover = rails.cardCover(for: id)
        return SnapFeedHeroOrigin(
            post: tapped,
            stream: stream,
            hasHero: hasMedia && rails.cardFrame(for: id, in: host) != nil,
            cover: cover,
            style: .listMedia,
            frame: { [weak rails] space in rails?.cardFrame(for: id, in: space) },
            isOnScreen: { [weak rails] in rails?.isCardOnScreen(id) ?? false },
            setConcealed: { [weak rails, weak page] concealed in
                rails?.setCardConcealed(concealed, for: id)
                if !concealed { page?.endHeroFreeze() }
            },
            // The card takes off PLAYING, joining its own surface.
            donateLiveMedia: { [weak rails] in rails?.liveCardSurface(for: id) },
            depthView: { [weak page] in page },
            // EVERY card — see the note on this type.
            textReveal: cardReveal(
                for: tapped, cover: cover, rails: rails, page: page, closeStaged: closeStaged
            ),
            restingOverlay: { ForYouFollowingCardCell.makeOverlay(for: tapped) },
            willStageDismissal: { [weak rails, weak page] in
                stageClose(page: page, then: closeStaged) { rails?.bringCardIntoView(id) }
            }
        )
    }

    /// The window a card opens (a TEXT card) and closes (any card, once the
    /// feed is on a text page) through — marker-shaped, for the place page's
    /// reason (`PlaceProfileViewController.textRowReveal`): the feed is a
    /// pager, so the card and the page are the same post only until the first
    /// swipe. The card itself, drawn fresh as it rests, is the stand-in.
    static func cardReveal(
        for post: GalleryPost,
        cover: UIImage?,
        rails: ForYouRailsView,
        page: ForYouGridPage,
        closeStaged: @escaping () -> Void = {}
    ) -> TextRevealOrigin {
        let id = post.id
        // Handed the rails rather than capturing them: the closures below hold
        // them weakly, and a nested function naming the parameter would not.
        func standIn(_ rails: ForYouRailsView) -> UIView? {
            guard let size = rails.cardFrame(for: id, in: rails)?.size else { return nil }
            // The picture the card is showing NOW, or the one it showed at the
            // tap for a cell that has not drawn it again yet.
            let picture = rails.cardCover(for: id) ?? cover
            return ForYouFollowingCardCell.makeStandIn(for: post, cover: picture, size: size)
        }
        return TextRevealOrigin(
            rowFrame: { [weak rails] space in rails?.cardFrame(for: id, in: space) },
            captionEnd: nil,
            depthView: { [weak page] in page },
            makeDismissStandIn: { [weak rails] _ in rails.flatMap(standIn) },
            makePresentStandIn: { [weak rails] in rails.flatMap(standIn) },
            alignsPageToSource: false,
            pageFit: .covering,
            cornerRadius: ForYouFollowingCardCell.cornerRadius,
            // The card's own ground: the card fill for words, the brick's
            // floor for a picture — what the cell itself is painted.
            fill: post.kind == .text
                ? PostGridListRowCell.cardFillColor
                : PostGridTileCell.fillColor(for: post),
            setConcealed: { [weak rails] concealed in rails?.setCardConcealed(concealed, for: id) },
            willStageDismissal: { [weak rails, weak page] _ in
                stageClose(page: page, then: closeStaged) { rails?.bringCardIntoView(id) }
            },
            dismissalDidEnd: { [weak page] _ in page?.endHeroFreeze() }
        )
    }

    /// What every close from a row does before it reads a rect: pin the list's
    /// inset, then bring the item back into its row's view — the list VC's own
    /// order (`ForYouPostListViewController.textRowReveal`). `then` runs once
    /// both are done — the moment the close is about to measure.
    static func stageClose(
        page: ForYouGridPage?, then staged: () -> Void, bringIntoView: () -> Void
    ) {
        page?.beginHeroFreeze()
        bringIntoView()
        staged()
    }
}
