import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A card previews a caption; the post is where it is read. These pin the
/// boundary between the two — which captions get an affordance, which do not,
/// and what pressing it does.
///
/// Sized through the REAL cell at a real width, because the question the code
/// asks is a measurement ("does this text want more room than the cap allows")
/// and a test that stubbed the measurement would only be checking arithmetic
/// it wrote itself.
@MainActor
struct CaptionTruncationTests {
    /// An iPhone SE row: 375pt of screen, less the 16pt the list insets each
    /// side. Narrow on purpose — it is the width that makes captions wrap.
    private static let rowWidth: CGFloat = 343

    private static func post(_ caption: String) -> GalleryPost {
        GalleryPost(
            id: PostID("post-0001"),
            kind: .text,
            isRepost: false,
            thumbnailURL: nil,
            caption: caption,
            publishedAtMS: 1_780_000_000_000
        )
    }

    private static func sized(_ caption: String, expanded: Bool = false) -> PostGridListRowCell {
        let cell = PostGridListRowCell(
            frame: CGRect(x: 0, y: 0, width: rowWidth, height: 200)
        )
        cell.configure(
            with: post(caption), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            captionExpanded: expanded
        )
        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        attributes.frame = CGRect(x: 0, y: 0, width: rowWidth, height: 200)
        _ = cell.preferredLayoutAttributesFitting(attributes)
        cell.layoutIfNeeded()
        return cell
    }

    private static func revealButton(in cell: UIView) -> UIButton? {
        var stack: [UIView] = [cell]
        while let view = stack.popLast() {
            if let button = view as? UIButton { return button }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private static func captionLabel(in cell: UIView) -> UILabel? {
        var stack: [UIView] = [cell]
        var found: [UILabel] = []
        while let view = stack.popLast() {
            if let label = view as? UILabel { found.append(label) }
            stack.append(contentsOf: view.subviews)
        }
        // The caption is the only label set to a multi-line body font; the
        // metric line's are footnotes on one line.
        return found.first { $0.font == .preferredFont(forTextStyle: .body) }
    }

    private static let long = """
        Shipping the new build tonight. The changelog is longer than I expected: two \
        crashes that only reproduced on a cold launch, a migration that had been \
        silently no-oping since spring, and a rewrite of the retry logic that finally \
        makes sense.
        """

    @Test func aCaptionThatFitsIsOfferedNothing() throws {
        let cell = Self.sized("Shipping the new build tonight.")
        let button = try #require(Self.revealButton(in: cell))
        #expect(button.isHidden)
    }

    @Test func aCaptionThatOverrunsTheCapIsOfferedTheRest() throws {
        let cell = Self.sized(Self.long)
        let button = try #require(Self.revealButton(in: cell))
        #expect(!button.isHidden)
        #expect(button.title(for: .normal) == "Show more")
        // Capped, and truncating — the ellipsis is what says there is more.
        let label = try #require(Self.captionLabel(in: cell))
        #expect(label.numberOfLines == PostGridListRowCell.captionLineLimit)
        #expect(label.lineBreakMode == .byTruncatingTail)
    }

    /// The affordance retires once it has been used: the expansion is one-way,
    /// so leaving a control that can no longer do anything would be a lie.
    @Test func pressingItRevealsEverythingAndRetiresTheAffordance() throws {
        let cell = Self.sized(Self.long)
        var asked = 0
        cell.onRevealFullCaption = { asked += 1 }

        // The button really is wired to the handler the hook calls — the half
        // `debugTapShowMore` cannot exercise without an app host.
        let wiring = try #require(Self.revealButton(in: cell))
            .actions(forTarget: cell, forControlEvent: .touchUpInside)
        #expect(wiring?.contains("revealTapped") == true)

        #expect(cell.debugTapShowMore())
        #expect(asked == 1)

        let label = try #require(Self.captionLabel(in: cell))
        #expect(label.numberOfLines == 0)
        // Word wrapping now, or "show more" would have revealed an ellipsis.
        #expect(label.lineBreakMode == .byWordWrapping)
        let button = try #require(Self.revealButton(in: cell))
        #expect(button.isHidden)
    }

    /// A row dequeued for a post the HOST says is expanded comes up whole —
    /// this is the path that survives recycling, and the reason the state does
    /// not live in the cell.
    @Test func aRowConfiguredAsExpandedComesUpWhole() throws {
        let cell = Self.sized(Self.long, expanded: true)
        let label = try #require(Self.captionLabel(in: cell))
        #expect(label.numberOfLines == 0)
        let button = try #require(Self.revealButton(in: cell))
        #expect(button.isHidden)
    }

    /// Recycling resets it. A reused cell that kept the previous post's
    /// expansion would show a short caption with no affordance and a long one
    /// already open.
    @Test func reuseTakesTheExpansionBack() throws {
        let cell = Self.sized(Self.long)
        #expect(cell.debugTapShowMore())
        cell.prepareForReuse()

        let label = try #require(Self.captionLabel(in: cell))
        #expect(label.numberOfLines == PostGridListRowCell.captionLineLimit)
        // …and the host's callback goes with it, so the recycled row cannot
        // report an expansion against the post it used to show.
        #expect(cell.onRevealFullCaption == nil)
    }

    /// The state store is keyed by POST, which is what makes it survive the
    /// cell it was set from.
    @Test func expansionIsRememberedPerPost() {
        let store = CaptionExpansion()
        let a = PostID("post-0001")
        let b = PostID("post-0002")
        #expect(!store.isExpanded(a))

        store.expand(a, in: UICollectionView(
            frame: .zero, collectionViewLayout: UICollectionViewFlowLayout()
        ))
        #expect(store.isExpanded(a))
        #expect(!store.isExpanded(b))

        store.reset()
        #expect(!store.isExpanded(a))
    }
}
