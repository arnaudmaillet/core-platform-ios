import CoreModels
import FeedInterface
import Testing
import UIKit
@testable import Upload

@MainActor
struct UploadFeatureBuilderTests {
    /// Stands in for Feed's screen, keeping the publisher it is handed.
    private final class RecordingTextPostScreens: TextPostScreenBuilding {
        var publisher: (any TextPostPublishing)?

        func makeTextPostScreen(publisher: any TextPostPublishing) -> UIViewController {
            self.publisher = publisher
            return UIViewController()
        }
    }

    private actor RecordingComposer: PostComposing {
        struct Call: Sendable {
            let hasMedia: Bool
            let caption: String
            let author: AuthorSummary?
        }

        private(set) var calls: [Call] = []

        func publish(media: ComposeMedia?, caption: String, as author: AuthorSummary?) async throws -> FeedEntry {
            calls.append(Call(hasMedia: media != nil, caption: caption, author: author))
            let by = author ?? AuthorSummary(id: ProfileID("first"), handle: "first", displayName: "First", avatarURL: nil)
            return FeedEntry(
                post: Post(id: PostID("new"), authorID: by.id, caption: caption, attachments: [], publishedAt: Date()),
                author: by
            )
        }
    }

    /// Text Post is Feed's screen, and what it publishes goes through the one
    /// pipeline — as a post with no media, by the author the screen names.
    @Test func theTextPostIsFeedsScreenPublishingThroughTheComposer() async throws {
        let screens = RecordingTextPostScreens()
        let composer = RecordingComposer()
        let builder = UploadFeatureBuilder(composer: composer, textPostScreens: { screens })

        _ = builder.makeTextPostViewController()
        let publisher = try #require(screens.publisher)
        let author = AuthorSummary(id: ProfileID("second"), handle: "two", displayName: "Two", avatarURL: nil)
        let entry = try await publisher.publishTextPost("Hello", as: author)

        let calls = await composer.calls
        #expect(calls.count == 1)
        #expect(calls.first?.hasMedia == false)
        #expect(calls.first?.caption == "Hello")
        #expect(calls.first?.author == author)
        #expect(entry.post.caption == "Hello")
    }

    /// Upload Media is still its own screen, and it can be closed from a
    /// control — a sheet whose only way out is a swipe nobody is told about is
    /// a trap, however empty it is.
    @Test func theMediaEntryIsStillItsOwnClosableScreen() throws {
        let builder = UploadFeatureBuilder(
            composer: RecordingComposer(), textPostScreens: { RecordingTextPostScreens() }
        )
        let root = try #require(
            (builder.makeMediaUploadViewController() as? UINavigationController)?.viewControllers.first
        )

        #expect(root.title == "Upload Media")
        #expect(root.navigationItem.leftBarButtonItem != nil)
    }
}
