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
