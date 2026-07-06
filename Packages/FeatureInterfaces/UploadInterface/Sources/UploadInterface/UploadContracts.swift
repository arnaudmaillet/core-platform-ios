import UIKit

/// Entry point contract for the compose/upload feature. The app shell presents
/// the returned view controller (typically modally). Success is observed by the
/// feed via the shared `ComposedPostChannel`, not a callback — so the composer
/// stays decoupled from whoever presented it.
@MainActor
public protocol UploadFeatureBuilding {
    func makeComposeViewController() -> UIViewController
}
