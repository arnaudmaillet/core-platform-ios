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

    /// ⚠️ A MEDIA CARD'S COUNT IS A CONTROL; A TEXT CARD'S IS NOT — and the
    /// pill is drawn identically either way.
    ///
    /// The shortcut exists because a media post opens onto its PHOTOGRAPH and
    /// its thread is a second surface, so pressing the count is the only way to
    /// ask for the thread directly. A text post's page IS its thread: tapping
    /// anywhere on the card already arrives there, by its own reveal. A chip
    /// promising a shortcut to where the card goes anyway is a second control
    /// for one destination — and it took the wrong route to get there, the
    /// media flight instead of the text reveal.
    ///
    /// Both shapes are asserted together because the two pairs of counters live
    /// on every row — the media overlay's and the closing line's — and which is
    /// shown is decided several levels up. A rule applied to one of them is
    /// half a rule.
    @Test func onlyAMediaCardsCountIsAControl() {
        var media = 0, text = 0

        let withPhoto = row(kind: .photo)
        withPhoto.onCommentsTapped = { media += 1 }
        #expect(withPhoto.debugTapCommentsChip())

        let withoutPhoto = row(kind: .text)
        withoutPhoto.onCommentsTapped = { text += 1 }
        #expect(withoutPhoto.debugTapCommentsChip() == false)

        #expect(media == 1)
        #expect(text == 0)
    }

    /// ⚠️ AND IT IS TURNED OFF, NOT HIDDEN. The touch has to reach the row.
    ///
    /// A chip that stayed interactive and did nothing would swallow the tap and
    /// leave the card unopenable at that spot — worse than either behaviour it
    /// sits between. Asserted on `isUserInteractionEnabled`, which is what
    /// decides whether the touch falls through.
    ///
    /// Scoped to the pills the viewer can actually SEE: a text row still
    /// carries the media card's chips, hidden, and a hidden view takes no
    /// touches whatever its flags say.
    @Test func aTextCardsCountLetsTheTouchThrough() {
        let cell = row(kind: .text)
        let live = pills(in: cell).filter { $0.superviewChainIsVisible }

        #expect(live.isEmpty == false)
        #expect(live.allSatisfy { $0.isUserInteractionEnabled == false })
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
