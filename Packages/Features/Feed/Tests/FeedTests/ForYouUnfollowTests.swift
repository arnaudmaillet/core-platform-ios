import CoreModels
import Foundation
import PostGrid
import Testing
@testable import Feed

/// What an unfollow does to the surface it was raised from.
///
/// Following is the people the viewer follows, so an author they no longer
/// follow has nothing left to be doing there — leaving their rows in place
/// reads as a failed tap. Discover is everyone, so it keeps them.
@MainActor
struct ForYouUnfollowTests {
    private func post(_ id: String, by author: String, kind: GalleryPost.Kind = .photo) -> GalleryPost {
        GalleryPost(
            id: PostID(id),
            kind: kind,
            isRepost: false,
            thumbnailURL: nil,
            caption: "caption \(id)",
            publishedAtMS: 10,
            authorID: ProfileID(author)
        )
    }

    private func loaded(_ posts: [GalleryPost]) async -> (ForYouViewModel, () -> Int) {
        let provider = UnfollowStubProvider(posts: posts)
        let model = ForYouViewModel(repository: provider)
        var resets = 0
        model.onCorpusReset = { resets += 1 }
        model.viewDidLoad()
        for _ in 0..<40 where model.posts(for: .activity).isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return (model, { resets })
    }

    @Test func theAuthorsPostsLeaveTheSurface() async {
        let (model, _) = await loaded([
            post("a1", by: "sofia"), post("b1", by: "marcus"), post("a2", by: "sofia")
        ])

        model.removeAuthor(ProfileID("sofia"))

        #expect(model.posts(for: .activity).map(\.id.rawValue) == ["b1"])
    }

    /// Following loses them; DISCOVER KEEPS THEM — it is everyone, followed
    /// or not, so an author the viewer just stopped following is still
    /// discoverable there, in the list and in the pushed mosaic (`.media`).
    @Test func onlyFollowingLosesThem() async {
        let (model, _) = await loaded([
            post("photo", by: "sofia", kind: .photo),
            post("text", by: "sofia", kind: .text),
            post("kept", by: "marcus", kind: .photo)
        ])

        model.removeAuthor(ProfileID("sofia"))

        // Following's pages: Short held only this author's text, so it empties.
        #expect(model.posts(for: .activity).map(\.id.rawValue) == ["kept"])
        #expect(model.posts(for: .short).isEmpty)
        // Discover's: untouched.
        #expect(model.discoverPosts.map(\.id.rawValue) == ["photo", "text", "kept"])
        #expect(model.posts(for: .media).map(\.id.rawValue) == ["photo", "kept"])
    }

    /// Unfollowing twice is one removal: the second changes nothing.
    @Test func aSecondUnfollowChangesNothing() async {
        let (model, resets) = await loaded([post("a1", by: "sofia"), post("b1", by: "marcus")])
        model.removeAuthor(ProfileID("sofia"))
        let before = resets()

        model.removeAuthor(ProfileID("sofia"))

        #expect(resets() == before)
    }

    /// A removal RE-DERIVES the corpus rather than extending it, and the pages
    /// diff incrementally — told nothing, they leave the rows on screen after
    /// the model has dropped them.
    @Test func thePagesAreToldTheCorpusChangedShape() async {
        let (model, resets) = await loaded([post("a1", by: "sofia"), post("b1", by: "marcus")])
        let before = resets()

        model.removeAuthor(ProfileID("sofia"))

        #expect(resets() == before + 1)
    }

    /// Nothing to remove, nothing to announce — an unfollow from a surface that
    /// was showing none of that author's posts must not make every page
    /// re-derive for no reason.
    @Test func anAuthorWithNothingHereChangesNothing() async {
        let (model, resets) = await loaded([post("b1", by: "marcus")])
        let before = resets()

        model.removeAuthor(ProfileID("nobody"))

        #expect(resets() == before)
        #expect(model.posts(for: .activity).map(\.id.rawValue) == ["b1"])
    }
}

private final class UnfollowStubProvider: ForYouProviding, @unchecked Sendable {
    private let posts: [GalleryPost]
    init(posts: [GalleryPost]) { self.posts = posts }
    func firstPage() async throws -> ForYouPage { ForYouPage(posts: posts, nextPageToken: nil) }
    func page(after token: String) async throws -> ForYouPage {
        ForYouPage(posts: [], nextPageToken: nil)
    }
}
