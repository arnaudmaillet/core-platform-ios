import CoreModels
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The caption row is the gallery card's TWIN — a reveal opens the row into the
/// page, so the row's closing line and the page's first line are one line seen
/// twice. These pin that the two spell the same instant the same way.
///
/// The failure they guard against is a last frame, which is the hardest kind to
/// notice: everything animates correctly and then one word changes. Three
/// producers spelled one timestamp three ways — the card said "28 May", the
/// hydrated model said "28 May 2026", and the seeded projection said
/// "12 weeks" — and the swap was invisible until the comments around it stopped
/// covering for it.
@MainActor
struct CaptionRowRegisterTests {
    /// Twelve weeks back, which is past every relative bracket and into the
    /// calendar-date one — the register where the three producers disagreed
    /// most loudly.
    private static let published = Date(timeIntervalSince1970: 1_770_000_000)
    private static let now = Date(timeIntervalSince1970: 1_770_000_000 + 12 * 7 * 86_400)

    private static var cardSpelling: String {
        PostMetadata.compactAge(
            ofMillis: Int64(published.timeIntervalSince1970 * 1000), now: now
        )
    }

    /// The HYDRATED row — what the page shows once its entry has landed.
    @Test func theHydratedRowSpellsTheAgeAsTheCardDoes() {
        let model = PostDetailDisplayModel(
            entry: FeedEntry(
                post: Post(
                    id: PostID("post-0001"), authorID: ProfileID("p1"),
                    caption: "Refactor landed.", attachments: [],
                    publishedAt: Self.published
                ),
                author: AuthorSummary(
                    id: ProfileID("p1"), handle: "ava", displayName: "Ava Moreau",
                    avatarURL: nil
                )
            ),
            now: Self.now
        )
        #expect(model.timestampText == Self.cardSpelling)
    }

    /// And the SEEDED one — what it shows for the length of the first fetch,
    /// which on a reveal is the whole of the transition.
    ///
    /// Both, because they have to agree with EACH OTHER as much as with the
    /// card: a row that matches the card while seeded and then rewrites itself
    /// when the entry lands has moved the pop rather than removed it.
    @Test func theSeededRowSpellsItTheSameWay() {
        let seeded = GalleryPostProjection.seedModel(from: GalleryPost(
            id: PostID("post-0001"),
            kind: .text,
            isRepost: false,
            thumbnailURL: nil,
            caption: "Refactor landed.",
            publishedAtMS: Int64(Self.published.timeIntervalSince1970 * 1000)
        ))
        // `seedModel` reads its own `now`, so this compares REGISTERS rather
        // than strings: a calendar date either side, not one of them counting
        // weeks. Comparing the literal text would pin the clock instead of the
        // formatter, which is how this repo has failed CI before.
        #expect(!seeded.timestampText.contains("week"))
        #expect(seeded.timestampText == PostMetadata.compactAge(
            ofMillis: Int64(Self.published.timeIntervalSince1970 * 1000)
        ))
    }
}
