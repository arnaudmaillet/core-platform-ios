import FeedInterface
import UIKit

/// The screens behind the tab bar's "+" menu that belong to this package:
/// Upload Media and Text Post.
///
/// TEXT POST IS DRAWN BY FEED. It is a text post's own page, born empty — the
/// same header, stream, composer and footer — and the first message the viewer
/// sends is published as the post, which the page then becomes. Upload supplies
/// the part it owns: `PostComposer`, behind Feed's `TextPostPublishing`.
///
/// ⚠️ UPLOAD MEDIA IS STILL EMPTY, ON PURPOSE. The menu came first so the "+"
/// could be tried end to end, and each screen gets designed on its own. Whatever
/// it becomes, it publishes through `PostComposer` too.
@MainActor
public struct UploadFeatureBuilder {
    private let composer: any PostComposing
    /// A closure rather than a value, for the reason Chat's `threadScreens` is
    /// one: the composition root builds the feed builder lazily, and the feed
    /// builder reaches the router, which reaches back here.
    private let textPostScreens: () -> any TextPostScreenBuilding

    public init(
        composer: any PostComposing,
        textPostScreens: @escaping () -> any TextPostScreenBuilding
    ) {
        self.composer = composer
        self.textPostScreens = textPostScreens
    }

    /// "Upload Media" — a photo or a video from the library.
    public func makeMediaUploadViewController() -> UIViewController {
        UINavigationController(rootViewController: PendingScreenViewController(title: "Upload Media"))
    }

    /// "Text Post" — a post with no media, written on its own page.
    public func makeTextPostViewController() -> UIViewController {
        textPostScreens().makeTextPostScreen(publisher: ComposerTextPostPublisher(composer: composer))
    }
}
