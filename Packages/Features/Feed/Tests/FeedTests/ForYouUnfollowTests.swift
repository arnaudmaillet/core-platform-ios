import CoreModels
import Foundation
import PostGrid
import Testing
@testable import Feed

/// What an unfollow does to the surface it was raised from.
///
/// This screen IS the following feed — both its tabs are orderings of
/// `timeline.v1.GetFollowingFeed`, there is no discovery corpus — so an author
/// the viewer no longer follows has nothing left to be doing on it. Leaving
/// their rows in place is the version of this that reads as a failed tap.
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

    /// Both pages, because Discover is an ORDERING of the following corpus and
    /// not a second one: a post that does not belong on one does not belong on
    /// the other.
    @Test func everyPageLosesThemTogether() async {
        let (model, _) = await loaded([
            post("photo", by: "sofia", kind: .photo),
            post("text", by: "sofia", kind: .text),
            post("kept", by: "marcus", kind: .photo)
        ])

        model.removeAuthor(ProfileID("sofia"))

        // Media keeps the other author's photo and loses this one's; Short held
        // only this author's text, so it empties.
        #expect(model.posts(for: .media).map(\.id.rawValue) == ["kept"])
        #expect(model.posts(for: .short).isEmpty)
        #expect(model.posts(for: .activity).map(\.id.rawValue) == ["kept"])
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
