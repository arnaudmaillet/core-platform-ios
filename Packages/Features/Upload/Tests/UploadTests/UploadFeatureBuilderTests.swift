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

        func publish(media: [ComposeMedia], caption: String, as author: AuthorSummary?) async throws -> FeedEntry {
            calls.append(Call(hasMedia: !media.isEmpty, caption: caption, author: author))
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

    /// Upload Media opens on the library picker FULL SCREEN (#1904, the owner
    /// 2026-10-30): a multistep edit, no card over the media, no grabber to
    /// drop a selection with — and a way out in its own bar.
    @Test func theMediaEntryOpensThePickerFullScreen() throws {
        let builder = UploadFeatureBuilder(
            composer: RecordingComposer(), textPostScreens: { RecordingTextPostScreens() }
        )
        let navigation = try #require(builder.makeMediaUploadViewController() as? UINavigationController)
        let root = try #require(navigation.viewControllers.first)

        #expect(navigation.modalPresentationStyle == .fullScreen, "full screen, not a sheet")
        #expect(root is MediaPickerViewController)
        #expect(
            root.navigationItem.leftBarButtonItems?.first?.title == "Cancel",
            "the way out the top bar promises"
        )
    }

    /// The camera opens full screen too (#1904), with no status bar over its
    /// preview, as the system's Camera app.
    @Test func theCameraOpensFullScreenWithoutAStatusBar() throws {
        let builder = UploadFeatureBuilder(
            composer: RecordingComposer(), textPostScreens: { RecordingTextPostScreens() }
        )
        let navigation = try #require(builder.makeCameraViewController() as? UINavigationController)
        #expect(navigation.modalPresentationStyle == .fullScreen)
        let camera = try #require(navigation.viewControllers.first as? CaptureViewController)
        #expect(navigation.childForStatusBarHidden === camera)
        #expect(camera.prefersStatusBarHidden)
    }
}
