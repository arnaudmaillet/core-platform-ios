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

    /// Upload Media opens on the library picker as a sheet that rests on one
    /// row of the album and opens into the whole grid, with a way out in its own
    /// bar — a screen whose only exit is a swipe nobody is told about is a trap.
    @Test func theMediaEntryOpensThePickerAsASheetRestingOnOneRow() throws {
        let builder = UploadFeatureBuilder(
            composer: RecordingComposer(), textPostScreens: { RecordingTextPostScreens() }
        )
        let navigation = try #require(builder.makeMediaUploadViewController() as? UINavigationController)
        let root = try #require(navigation.viewControllers.first)
        let sheet = try #require(navigation.sheetPresentationController)

        #expect(navigation.modalPresentationStyle == .pageSheet, "a sheet, not full screen")
        #expect(sheet.detents.count == 2, "one row, and the whole album")
        #expect(
            sheet.selectedDetentIdentifier == MediaPickerViewController.restingDetentIdentifier,
            "and it arrives on the small one"
        )
        #expect(root is MediaPickerViewController)
        #expect(
            root.navigationItem.leftBarButtonItems?.first?.title == "Cancel",
            "the way out the top bar promises"
        )
    }
}
