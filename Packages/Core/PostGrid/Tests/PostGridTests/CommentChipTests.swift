import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// The comment count is a control, and it goes somewhere the card's own tap
/// does not.
@MainActor
struct CommentChipTests {
    private func pills(in view: UIView) -> [PostMetaPillView] {
        if let pill = view as? PostMetaPillView { return [pill] }
        return view.subviews.flatMap(pills(in:))
    }

    private func row(kind: GalleryPost.Kind, comments: Int64 = 12) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 520))
        cell.configure(
            with: GalleryPost(
                id: PostID("post-1"),
                kind: kind,
                isRepost: false,
                thumbnailURL: kind == .text ? nil : URL(string: "mock://photo/1"),
                caption: "Golden hour over the harbour.",
                publishedAtMS: 0,
                reactionCount: 160,
                commentCount: comments,
                viewCount: 4_200
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
        return cell
    }

    /// ⚠️ EVERY CARD'S COUNT IS A CONTROL, TEXT POSTS INCLUDED.
    ///
    /// A text card's chip used to be switched off — its page IS its thread,
    /// so the chip was left drawn and dead — and that was reported from a
    /// device as a button that "does not work": the same capsule shrank under
    /// the finger on a media card and did nothing on a text card. The chip now
    /// always presses; where a text post's comments are is the HOST's answer
    /// (`ForYouGridPage.open` sends it down the card's own reveal).
    @Test func everyCardsCountIsAControl() {
        var media = 0, text = 0

        let withPhoto = row(kind: .photo)
        withPhoto.onCommentsTapped = { media += 1 }
        #expect(withPhoto.debugTapCommentsChip())

        let withoutPhoto = row(kind: .text)
        withoutPhoto.onCommentsTapped = { text += 1 }
        #expect(withoutPhoto.debugTapCommentsChip())

        #expect(media == 1)
        #expect(text == 1)
    }

    /// And it TAKES the touch on a text card too — a chip that presses must
    /// own its finger, or the row under it would open the post as well.
    @Test func aTextCardsCountTakesTheTouch() {
        let cell = row(kind: .text)
        let comments = pills(in: cell).filter {
            $0.superviewChainIsVisible && $0.accessibilityLabel == "Comments"
        }

        #expect(comments.count == 1)
        #expect(comments.allSatisfy { $0.isUserInteractionEnabled })
    }

    /// ⚠️ AND IT IS NOT THE ROW'S OWN TAP.
    ///
    /// The whole point is a different destination — the post at its thread
    /// rather than the post at its photograph. A chip that also fired the row's
    /// handler would open the post twice, in an order nobody chose, and the
    /// second answer would win.
    @Test func theChipDoesNotAlsoOpenThePostNormally() {
        let cell = row(kind: .photo)
        var opened = 0, commented = 0
        cell.onMediaTapped = { opened += 1 }
        cell.onCommentsTapped = { commented += 1 }

        #expect(cell.debugTapCommentsChip())

        #expect(commented == 1)
        #expect(opened == 0)
    }

    /// A recycled row must not carry the previous post's handler: the chip
    /// would open a thread belonging to someone else's post.
    ///
    /// ⚠️ It stays a CONTROL through the recycle, and only stops having
    /// somewhere to send the touch. The chip is wired once when the row is
    /// built, not per post — so the thing that has to be forgotten is the
    /// row's handler, and pressing a recycled row before it is configured is
    /// harmless rather than impossible.
    @Test func aRecycledRowForgetsTheHandler() {
        let cell = row(kind: .photo)
        var fired = 0
        cell.onCommentsTapped = { fired += 1 }

        cell.prepareForReuse()
        _ = cell.debugTapCommentsChip()

        #expect(fired == 0)
    }

    /// ⚠️ A PILL IS FURNITURE UNTIL SOMETHING GIVES IT SOMEWHERE TO SEND A
    /// TOUCH.
    ///
    /// `PostMetaPillView` turns interaction off deliberately — the card's own
    /// tap opens the post, and chips that swallowed touches for nothing would
    /// put dead corners on the preview. Asserted in both directions, because
    /// the fix for "the chip does nothing" is one line from "every chip is a
    /// hole in the card".
    @Test func aPillTakesTouchesOnlyWhenItIsWired() {
        let pill = PostMetaPillView(contents: [UILabel()])
        #expect(pill.isUserInteractionEnabled == false)

        pill.setTapHandler {}
        #expect(pill.isUserInteractionEnabled)

        pill.setTapHandler(nil)
        #expect(pill.isUserInteractionEnabled == false)
    }
}
