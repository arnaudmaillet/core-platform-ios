import CoreModels
import EmoteKit
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A card's caption animates its emotes, and the "… Show more" truncation
/// cuts the MARKED text: a `:code:` is one glyph that no word boundary splits.
@MainActor
struct CaptionEmoteTests {
    private static let rowWidth: CGFloat = 343

    private static func sized(_ caption: String) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: rowWidth, height: 200))
        cell.configure(
            with: GalleryPost(
                id: PostID("post-0001"), kind: .text, isRepost: false, thumbnailURL: nil,
                caption: caption, publishedAtMS: 1_780_000_000_000
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = CGRect(x: 0, y: 0, width: rowWidth, height: 200)
        _ = cell.preferredLayoutAttributesFitting(attributes)
        cell.layoutIfNeeded()
        return cell
    }

    private static func caption(in cell: UIView) -> EmoteLabel? {
        var stack: [UIView] = [cell]
        while let view = stack.popLast() {
            if let label = view as? EmoteLabel { return label }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private static func marks(_ text: NSAttributedString) -> Int {
        var count = 0
        text.enumerateAttribute(EmoteText.emoteAttribute, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { count += (text.string as NSString).substring(with: range).count }
        }
        return count
    }

    @Test func aShortCaptionMarksItsEmotes() throws {
        let label = try #require(Self.caption(in: Self.sized("done :lol: 🔥")))
        let text = try #require(label.attributedText)
        #expect(text.string == "done 😆 🔥")
        #expect(Self.marks(text) == 2)
    }

    /// Whatever word the cut lands on, no code is left half-written.
    @Test func truncationNeverLeavesAHalfCode() throws {
        for padding in 0..<12 {
            let words = String(repeating: "word ", count: 30 + padding)
            let caption = words + ":lol: " + words + ":lmao: end"
            let label = try #require(Self.caption(in: Self.sized(caption)))
            let text = try #require(label.attributedText)
            #expect(text.string.hasSuffix("Show more"))
            #expect(!text.string.contains(":"), "a code was cut: \(text.string.suffix(40))")
        }
    }
}
