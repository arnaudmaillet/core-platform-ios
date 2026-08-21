import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// The card a reveal's dismissal carries home.
///
/// It moved into PostGrid because BOTH surfaces that draw a post as a row need
/// it — For You had one and a profile gallery did not, which is the whole
/// reason the two screens' reveals did not feel the same. Now that one type
/// serves both, what it guarantees is worth pinning.
@MainActor
struct RevealDismissCardTests {
    private func post(caption: String = "a short note") -> GalleryPost {
        GalleryPost(
            id: PostID("post-1"),
            kind: .text,
            isRepost: false,
            thumbnailURL: nil,
            caption: caption,
            publishedAtMS: 0,
            authorID: ProfileID("prof-1"),
            authorName: "Ada Lovelace",
            authorHandle: "ada"
        )
    }

    private func standIn(
        width: CGFloat, caption: String = "a short note", expanded: Bool = false
    ) -> RevealDismissCardView {
        RevealDismissCardView(
            post: post(caption: caption),
            width: width,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            captionExpanded: expanded
        )
    }

    /// A caption long enough to truncate at the row's four-line limit.
    private var longCaption: String {
        String(repeating: "Shipping the new build tonight and the changelog is long. ", count: 8)
    }

    /// The card is laid out at the ROW's width, and sized to the height that
    /// width implies — a cell left as built keeps its construction size, and
    /// every rect read off it would be that size rather than the row's.
    @Test func theCardIsSizedToTheRowsWidth() {
        let view = standIn(width: 343)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
        view.layoutIfNeeded()

        let card = view.subviews.first
        #expect(card?.bounds.width == 343)
        #expect((card?.bounds.height ?? 0) > 0)
    }

    /// CENTRED in the window, not pinned. The window is wider than the card at
    /// the start of a flight, and stretching the card to meet it would re-wrap
    /// the caption mid-flight.
    @Test func theCardStaysCentredAtAnyWindowSize() {
        let view = standIn(width: 343)
        for size in [CGSize(width: 402, height: 800), CGSize(width: 360, height: 200)] {
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
            let card = try? #require(view.subviews.first)
            #expect(abs((card?.center.x ?? 0) - size.width / 2) < 0.5)
            #expect(abs((card?.center.y ?? 0) - size.height / 2) < 0.5)
        }
    }

    /// Two opacities, not one: the view is the card's FILL and the card is what
    /// it holds, and the hand-off fades them on different schedules.
    @Test func theFillAndItsContentsFadeIndependently() {
        let view = standIn(width: 343)
        view.alpha = 0.4
        view.setContentOpacity(0.1)

        // Compared with a tolerance, never `==`: these are `CGFloat`s round-
        // tripped through a float, and 0.4 comes back as 0.40000000596.
        #expect(abs(view.alpha - 0.4) < 0.001)
        #expect(abs((view.subviews.first?.alpha ?? 0) - 0.1) < 0.001)
    }

    /// A viewer who opened a caption out with "Show more" and then opened the
    /// post must not have a TRUNCATED card flown home to them: it lands on a
    /// row that is showing the whole text, so the last frame changes both the
    /// words and the height.
    @Test func anOpenedCaptionTravelsHomeOpened() {
        let truncated = standIn(width: 343, caption: longCaption, expanded: false)
        let opened = standIn(width: 343, caption: longCaption, expanded: true)
        for view in [truncated, opened] {
            view.frame = CGRect(x: 0, y: 0, width: 402, height: 900)
            view.layoutIfNeeded()
        }

        let truncatedHeight = truncated.subviews.first?.bounds.height ?? 0
        let openedHeight = opened.subviews.first?.bounds.height ?? 0
        #expect(openedHeight > truncatedHeight,
                "the stand-in ignored the expansion, so it flies the wrong card home")
    }

    /// The default is the truncated card, which is what a surface with no
    /// expansion state should get — the flag is an answer, not a guess.
    @Test func aShortCaptionIsTheSameEitherWay() {
        let plain = standIn(width: 343)
        let opened = standIn(width: 343, expanded: true)
        for view in [plain, opened] {
            view.frame = CGRect(x: 0, y: 0, width: 402, height: 900)
            view.layoutIfNeeded()
        }

        #expect(plain.subviews.first?.bounds.height == opened.subviews.first?.bounds.height)
    }

    /// The "..." is drawn exactly when the landing row draws one, and both ways
    /// of being wrong are a jump in the last frame. This is the one that
    /// shipped: the stand-in always drew it, and a viewer's own post has no
    /// menu, so every dismissal on your own profile ended with a control
    /// vanishing three frames after the window settled.
    @Test func theOverflowControlMatchesTheRowItLandsOn() {
        let shown = standIn(width: 343)
        let absent = RevealDismissCardView(
            post: post(),
            width: 343,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            showsAuthorMenu: false
        )
        for view in [shown, absent] {
            view.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
            view.layoutIfNeeded()
        }

        #expect(menuControl(in: shown)?.isHidden == false)
        #expect(menuControl(in: absent)?.isHidden == true)
    }

    /// The band's trailing control, found by shape rather than by name: it is
    /// the only square button the card holds.
    private func menuControl(in view: RevealDismissCardView) -> UIView? {
        func search(_ root: UIView) -> UIView? {
            for child in root.subviews {
                if let button = child as? UIButton,
                   abs(button.bounds.width - PostAuthorBandView.avatarDiameter) < 0.5,
                   abs(button.bounds.height - PostAuthorBandView.avatarDiameter) < 0.5 {
                    return button
                }
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(view)
    }

    /// THE INVARIANT THE WHOLE STAND-IN EXISTS FOR: its content sits exactly
    /// where the row's content sits.
    ///
    /// The window lands on the row's rect — measured, model and presentation
    /// frames both equal to the target — so any remaining jump at the swap is
    /// inside it: the same card, laid out twice, disagreeing about where its
    /// caption goes. That is invisible in a still and unmissable in motion.
    @Test func theStandInLaysItsContentWhereTheRowDoes() throws {
        let width: CGFloat = 370
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

        // The row, sized the way a collection view sizes a self-sizing cell.
        let row = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        row.configure(with: post(), imagePipeline: pipeline)
        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        attributes.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        let fitted = row.preferredLayoutAttributesFitting(attributes)
        row.frame = CGRect(origin: .zero, size: fitted.frame.size)
        row.layoutIfNeeded()

        // The stand-in, in a window of exactly the row's rect — the landing.
        let view = standIn(width: width)
        view.frame = CGRect(origin: .zero, size: fitted.frame.size)
        view.layoutIfNeeded()
        let card = try #require(view.subviews.first)

        for (label, rowRect, standInRect) in captionRects(row: row, card: card) {
            #expect(abs(rowRect.minY - standInRect.minY) < 0.5,
                    "\(label) is \(standInRect.minY - rowRect.minY)pt out")
        }
    }

    /// The y of each text run in both, paired by position in the tree.
    private func captionRects(
        row: PostGridListRowCell, card: UIView
    ) -> [(String, CGRect, CGRect)] {
        func labels(_ view: UIView, into found: inout [UILabel]) {
            for child in view.subviews {
                if let label = child as? UILabel, !(label.text ?? "").isEmpty {
                    found.append(label)
                }
                labels(child, into: &found)
            }
        }
        var rowLabels: [UILabel] = []
        var cardLabels: [UILabel] = []
        labels(row, into: &rowLabels)
        labels(card, into: &cardLabels)
        return zip(rowLabels, cardLabels).map { rowLabel, cardLabel in
            (rowLabel.text ?? "?",
             rowLabel.convert(rowLabel.bounds, to: row),
             cardLabel.convert(cardLabel.bounds, to: card))
        }
    }

    /// It takes no touches — it is scenery flying over a live screen.
    @Test func itIsInert() {
        #expect(standIn(width: 343).isUserInteractionEnabled == false)
    }

    /// The window's rounding is driven by the flight, so the stand-in is the
    /// window's shape at every size rather than a rectangle inside it.
    @Test func theFlightDrivesItsRounding() {
        let view = standIn(width: 343)
        view.setCornerRadius(26)
        #expect(view.layer.cornerRadius == 26)
    }
}
