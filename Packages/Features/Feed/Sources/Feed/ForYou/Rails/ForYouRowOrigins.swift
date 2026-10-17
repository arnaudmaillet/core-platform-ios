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
    /// A friend's story: their posts, opened out of their face.
    ///
    /// `nil` for a friend with nothing to open.
    static func story(
        _ story: ForYouViewModel.FriendStory,
        friends: FriendsStoriesRow,
        page: ForYouGridPage,
        host: UIView,
        largerFace: ((@escaping @MainActor (UIImage) -> Void) -> Void)? = nil,
        closeStaged: @escaping () -> Void = {}
    ) -> SnapFeedHeroOrigin? {
        guard story.posts.first != nil else { return nil }
        let author = story.authorID
        let face = StoryFace(friends.storyFace(for: author))
        // A sharper picture for the close, read while the posts are open: the
        // row's is decoded for a 60 pt face, and the close draws it at the
        // size of the screen first.
        largerFace? { [face] image in face.image = image }
        return SnapFeedHeroOrigin(
            post: story.posts[0],
            stream: story.posts,
            // ⚠️ NEVER A FLIGHT (#1356): a face is the friend's AVATAR, not
            // their post's picture, and a flight cross-dissolved the one into
            // the other — the avatar seen over the media as it grew, then the
            // landing's bounce. The window opens instead, the post itself
            // growing out of the face, as a story does (`storyReveal`).
            hasHero: false,
            cover: face.image,
            style: .listMedia,
            frame: { [weak friends] space in friends?.storyFrame(for: author, in: space) },
            isOnScreen: { [weak friends] in friends?.isStoryOnScreen(author) ?? false },
            setConcealed: { [weak friends, weak page] concealed in
                friends?.setStoryConcealed(concealed, for: author)
                // The flight's close is over once its source is put back.
                if !concealed { page?.endHeroFreeze() }
            },
            depthView: { [weak page] in page },
            // Every story opens and closes through it, whatever its posts.
            textReveal: storyReveal(
                for: author, face: face, friends: friends, page: page, closeStaged: closeStaged
            ),
            // The face's own outline — a nearly-round square, not a disc —
            // so the card leaves as the face and lands as it.
            cornerRadius: friends.storyFaceCornerRadius,
            cornerCurve: ForYouStoryCell.Metrics.faceShape.cornerCurve,
            willStageDismissal: { [weak friends, weak page] in
                stageClose(page: page, then: closeStaged) { friends?.bringStoryIntoView(author) }
            }
        )
    }

    /// The face a story's window carries back: the row's picture at the
    /// open, a sharper one once it has loaded.
    final class StoryFace {
        var image: UIImage?
        init(_ image: UIImage?) { self.image = image }
    }

    /// The window a story opens and closes through: the map marker's text-post
    /// window, out of a disc. Nothing to align (a face has no caption), the
    /// page covering the window whatever its shape, the face as the stand-in
    /// at both ends — whatever post the viewer ended on.
    static func storyReveal(
        for author: ProfileID,
        face: StoryFace,
        friends: FriendsStoriesRow,
        page: ForYouGridPage,
        closeStaged: @escaping () -> Void = {}
    ) -> TextRevealOrigin {
        let radius = friends.storyFaceCornerRadius
        func standIn() -> UIView? {
            guard let image = face.image else { return nil }
            let view = UIImageView(image: image)
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.layer.cornerRadius = radius
            view.layer.cornerCurve = ForYouStoryCell.Metrics.faceShape.cornerCurve
            return view
        }
        return TextRevealOrigin(
            rowFrame: { [weak friends] space in
                inView(friends?.storyFrame(for: author, in: space)) {
                    friends?.bringStoryIntoView(author)
                    return friends?.storyFrame(for: author, in: space)
                }
            },
            captionEnd: nil,
            depthView: { [weak page] in page },
            makeDismissStandIn: { _ in standIn() },
            // No stand-in on the way in (#1356): the window opens onto the
            // post itself, covering the face's shape from its first frame —
            // the avatar never drawn over the media.
            makePresentStandIn: { nil },
            alignsPageToSource: false,
            pageFit: .covering,
            cornerRadius: radius,
            cornerCurve: ForYouStoryCell.Metrics.faceShape.cornerCurve,
            fill: nil,
            setConcealed: { [weak friends] concealed in
                friends?.setStoryConcealed(concealed, for: author)
            },
            willStageDismissal: { [weak friends, weak page] _ in
                stageClose(page: page, then: closeStaged) { friends?.bringStoryIntoView(author) }
            },
            // Both ways: a close that sprang back is over too, and the list
            // under a page that is staying has nothing to hold still for.
            dismissalDidEnd: { [weak page] _ in page?.endHeroFreeze() }
        )
    }

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
