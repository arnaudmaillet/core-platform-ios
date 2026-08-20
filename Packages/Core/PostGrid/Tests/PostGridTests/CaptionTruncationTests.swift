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
    private static let token = "… Show more"

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

    /// The caption is the only label carrying a multi-line body font; the
    /// metric line's are footnotes.
    private static func captionLabel(in cell: UIView) -> UILabel? {
        var stack: [UIView] = [cell]
        var found: [UILabel] = []
        while let view = stack.popLast() {
            if let label = view as? UILabel { found.append(label) }
            stack.append(contentsOf: view.subviews)
        }
        return found.first { $0.font == .preferredFont(forTextStyle: .body) }
    }

    private static func rendered(_ cell: UIView) throws -> String {
        try #require(captionLabel(in: cell)?.attributedText?.string)
    }

    /// The lines `text` breaks into at a row's caption width — the same
    /// measurement the cell makes, so the test and the code agree about what a
    /// line is.
    private static func lines(_ text: String) -> [String] {
        let width = rowWidth - PostGridListRowCell.captionInset * 2
        let storage = NSTextStorage(
            string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
        )
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var result: [String] = []
        var index = 0
        while index < manager.numberOfGlyphs {
            var effective = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            let characters = manager.characterRange(
                forGlyphRange: effective, actualGlyphRange: nil
            )
            result.append((text as NSString).substring(with: characters))
            index = NSMaxRange(effective)
        }
        return result
    }

    private static func lineCount(_ text: String) -> Int { lines(text).count }

    private static let short = "Shipping the new build tonight."
    private static let long = """
        Shipping the new build tonight. The changelog is longer than I expected: two \
        crashes that only reproduced on a cold launch, a migration that had been \
        silently no-oping since spring, and a rewrite of the retry logic that finally \
        makes sense.
        """

    @Test func aCaptionThatFitsIsOfferedNothing() throws {
        let cell = Self.sized(Self.short)
        #expect(try Self.rendered(cell) == Self.short)
        #expect(!cell.debugTapShowMore())
    }

    @Test func aCaptionThatOverrunsTheCapEndsInTheAffordance() throws {
        let cell = Self.sized(Self.long)
        let text = try Self.rendered(cell)
        // INLINE, not on its own line: the affordance is the tail of the
        // sentence it interrupts.
        #expect(text.hasSuffix(Self.token))
        #expect(text.count < Self.long.count)
        #expect(Self.captionLabel(in: cell)?.numberOfLines
            == PostGridListRowCell.captionLineLimit)
    }

    /// The shown text is a real PREFIX of the caption, cut at a word boundary.
    /// Anything else would be the card inventing wording the post does not
    /// have — and a mid-word cut reads as a rendering fault rather than as an
    /// interruption.
    @Test func theShownTextIsAWordBoundaryPrefixOfTheCaption() throws {
        let text = try Self.rendered(Self.sized(Self.long))
        let prefix = String(text.dropLast(Self.token.count))
        #expect(Self.long.hasPrefix(prefix))
        let next = Self.long[Self.long.index(Self.long.startIndex, offsetBy: prefix.count)]
        #expect(next == " ")
    }

    /// The whole point of composing it by hand: the ellipsis and the
    /// affordance have to FIT inside the cap, or the line they sit on is the
    /// one the label truncates away.
    ///
    /// Counted in LINE FRAGMENTS, not in points. `boundingRect` returns the
    /// laid-out height including leading — four lines of body text measure 88pt
    /// against a 20.5pt line height — so a points-based assertion here fails on
    /// correct output, which is exactly what it did.
    @Test func theComposedTextStaysInsideTheCap() throws {
        let text = try Self.rendered(Self.sized(Self.long))
        #expect(Self.lineCount(text) <= PostGridListRowCell.captionLineLimit)
    }

    /// The affordance retires once it has been used: the expansion is one-way,
    /// so leaving something that can no longer do anything would be a lie.
    @Test func pressingItRevealsEverythingAndRetiresTheAffordance() throws {
        let cell = Self.sized(Self.long)
        var asked = 0
        cell.onRevealFullCaption = { asked += 1 }

        #expect(cell.debugTapShowMore())
        #expect(asked == 1)
        #expect(try Self.rendered(cell) == Self.long)
        #expect(Self.captionLabel(in: cell)?.numberOfLines == 0)
        // Nothing left to press, and pressing again must not report otherwise.
        #expect(!cell.debugTapShowMore())
        #expect(asked == 1)
    }

    /// A row dequeued for a post the HOST says is expanded comes up whole —
    /// this is the path that survives recycling, and the reason the state does
    /// not live in the cell.
    @Test func aRowConfiguredAsExpandedComesUpWhole() throws {
        let cell = Self.sized(Self.long, expanded: true)
        #expect(try Self.rendered(cell) == Self.long)
        #expect(Self.captionLabel(in: cell)?.numberOfLines == 0)
        #expect(!cell.debugTapShowMore())
    }

    /// Recycling resets it. A reused cell that kept the previous post's
    /// expansion would show a long caption already open.
    @Test func reuseTakesTheExpansionBack() throws {
        let cell = Self.sized(Self.long)
        #expect(cell.debugTapShowMore())
        cell.prepareForReuse()
        #expect(Self.captionLabel(in: cell)?.numberOfLines
            == PostGridListRowCell.captionLineLimit)
        // …and the host's callback goes with it, so the recycled row cannot
        // report an expansion against the post it used to show.
        #expect(cell.onRevealFullCaption == nil)
    }

    /// THE ANIMATION'S CONTRACT. Expanding may only ADD text; the lines the
    /// viewer was already reading must break in exactly the same places.
    ///
    /// It holds because the shown text is a literal prefix and line breaking is
    /// greedy left to right, so every line the affordance does not sit on is
    /// decided by the same characters either way. The LAST one is the exception
    /// and cannot not be — the affordance was occupying part of it.
    @Test func expandingDoesNotRebreakTheLinesAlreadyOnScreen() throws {
        let truncated = try Self.rendered(Self.sized(Self.long))
        let prefix = String(truncated.dropLast(Self.token.count))

        let before = Self.lines(prefix)
        let after = Self.lines(Self.long)
        #expect(before.count > 1)
        #expect(before.count <= PostGridListRowCell.captionLineLimit)
        for index in 0..<(before.count - 1) {
            #expect(before[index] == after[index])
        }
        // …and the affordance really is ON that last line rather than under
        // it: composing it adds no line.
        #expect(Self.lineCount(truncated) == before.count)
    }

    /// The caption draws from its TOP, which is what makes the expansion read
    /// as a reveal rather than as a jump.
    ///
    /// A label centres its text block inside its own bounds. Expanding sets the
    /// whole caption on a label whose frame is still four lines tall and then
    /// animates that frame open, so for the length of the animation the text is
    /// taller than the box holding it — and centred means the lines already on
    /// screen slide up and out before drifting back down.
    @Test func theCaptionDrawsFromItsTopSoExpandingDoesNotShiftIt() throws {
        let label = try #require(Self.captionLabel(in: Self.sized(Self.long)))
        #expect(label.contentMode == .top)
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
