import UIKit

/// The screens behind the tab bar's "+" menu that belong to this package:
/// Upload Media and Text Post.
///
/// ⚠️ BOTH ARE EMPTY, ON PURPOSE. The menu came first so the "+" can be tried
/// end to end, and each screen gets designed on its own afterwards. Whatever
/// they become, they publish through `PostComposer`, which is the part of this
/// package that already works.
@MainActor
public struct UploadFeatureBuilder {
    public init() {}

    /// "Upload Media" — a photo or a video from the library.
    public func makeMediaUploadViewController() -> UIViewController {
        UINavigationController(rootViewController: PendingScreenViewController(title: "Upload Media"))
    }

    /// "Text Post" — a post with no media.
    public func makeTextPostViewController() -> UIViewController {
        UINavigationController(rootViewController: PendingScreenViewController(title: "Text Post"))
    }
}
