import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Feed

/// THE BARS ARE NOT IN THE CELL, AND THEY CACHE.
///
/// The author capsule and the attribution pill are the two most identity-bearing
/// things on a full-screen page, and both are the SCREEN's chrome rather than
/// the page's — refreshed on a page change, not on a data change. Each also
/// short-circuits, for a good reason: paging past ten posts must not fire ten
/// cross-dissolves and ten avatar fetches.
///
/// Both short-circuits were keyed on IDENTITY, and identity is exactly what does
/// not change when a page rendered from a grid's projection is replaced by the
/// entry the network returns. The result was a page whose cell showed the real
/// post while the two pills above and below it kept the projection — measured as
/// `page CONFIGURE author=yes` in the same frame as a capsule reading nobody.
@MainActor
struct SnapChromeRefreshTests {
    private let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    private func model(
        id: String = "p1",
        author: String,
        authorID: String = "prof-1",
        meta: String,
        avatar: String? = nil,
        audio: String? = nil
    ) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id),
            authorID: ProfileID(authorID),
            authorName: author,
            metaText: meta,
            avatarURL: avatar.flatMap(URL.init(string:)),
            caption: "caption",
            mediaURL: nil,
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: audio,
            likeCount: 0,
            timestampText: "10 weeks"
        )
    }

    private func labels(in view: UIView) -> [String] {
        view.subviews.flatMap { subview -> [String] in
            var found = labels(in: subview)
            if let label = subview as? UILabel, let text = label.text, !text.isEmpty {
                found.append(text)
            }
            return found
        }
    }

    // MARK: - The attribution pill

    @Test func theAttributionPillFillsInWhenTheRealEntryLands() {
        let pill = SnapMediaAttributionView()
        pill.setPost(model(author: "", meta: "75d"), pipeline: pipeline)
        #expect(labels(in: pill).contains("75d"), "precondition: the projection is showing")

        pill.setPost(
            model(author: "Demo Viewer", meta: "@you · 75d"), pipeline: pipeline
        )

        #expect(labels(in: pill).contains("Demo Viewer"),
                "the pill kept the projection's anonymous author")
        #expect(labels(in: pill).contains("@you · 75d"))
    }

    /// The short-circuit still does its job — this is what stops a fast page-past
    /// from firing a cross-dissolve per post.
    @Test func theAttributionPillIgnoresAnIdenticalRepeat() {
        let pill = SnapMediaAttributionView()
        let settled = model(author: "Demo Viewer", meta: "@you · 75d")
        pill.setPost(settled, pipeline: pipeline)
        pill.setPost(settled, pipeline: pipeline)

        // Nothing to assert but the absence of a crash and a stable render; the
        // value here is that the guard is exercised at all, so a later change
        // that removes it fails the *other* test rather than passing both.
        #expect(labels(in: pill).contains("Demo Viewer"))
    }

    /// A video page's attribution is the track line, and it has to survive the
    /// same replacement — this is the "music/cover info" half of the overlay.
    @Test func theAttributionPillPicksUpAudioAttribution() {
        let pill = SnapMediaAttributionView()
        pill.setPost(model(author: "", meta: "75d"), pipeline: pipeline)

        pill.setPost(
            model(author: "Demo Viewer", meta: "@you · 75d", audio: "Original audio · @you"),
            pipeline: pipeline
        )

        #expect(labels(in: pill).contains("Original audio · @you"))
    }

    // MARK: - The author capsule

    @Test func theAuthorCapsuleFillsInWhenTheRealEntryLands() {
        let capsule = SnapAuthorIdentityView()
        capsule.setAuthor(model(author: "", authorID: "", meta: "75d"), pipeline: pipeline)

        capsule.setAuthor(
            model(author: "Demo Viewer", meta: "@you · 75d"), pipeline: pipeline
        )

        #expect(labels(in: capsule).contains("Demo Viewer"))
    }

    /// ⚠️ The case the `authorID`-keyed guard got wrong: the SAME person, whose
    /// name and face the projection did not carry. Keyed on the id alone this
    /// took the meta-only fast path and left the capsule blank-faced.
    @Test func theSameAuthorWithBetterDataStillRefreshes() {
        let capsule = SnapAuthorIdentityView()
        capsule.setAuthor(model(author: "", meta: "75d"), pipeline: pipeline)

        capsule.setAuthor(
            model(author: "Demo Viewer", meta: "@you · 75d", avatar: "https://cdn.example/a.jpg"),
            pipeline: pipeline
        )

        #expect(labels(in: capsule).contains("Demo Viewer"),
                "same author id took the fast path and never drew the name")
    }

    /// …while paging BETWEEN posts by one person still moves only the time,
    /// which is what the fast path is for.
    @Test func pagingWithinOneAuthorOnlyMovesTheTime() {
        let capsule = SnapAuthorIdentityView()
        capsule.setAuthor(model(id: "p1", author: "Demo Viewer", meta: "@you · 75d"), pipeline: pipeline)

        capsule.setAuthor(model(id: "p2", author: "Demo Viewer", meta: "@you · 2h"), pipeline: pipeline)

        #expect(labels(in: capsule).contains("@you · 2h"))
        #expect(labels(in: capsule).contains("Demo Viewer"))
    }
}
