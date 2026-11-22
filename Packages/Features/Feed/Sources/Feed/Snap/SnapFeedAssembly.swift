import MediaCore
import UIKit

/// The Snap feed's assembly: the feed's one construction and the three ways
/// a post opens into it (the hero flight, the plain push and the window),
/// with the dock's backstops. One type over four files: this one,
/// `+HeroOpening`, `+PlainOpening` and `+Dock`. Built once by
/// `FeedFeatureBuilder`.
@MainActor
struct SnapFeedAssembly {
    let imagePipeline: ImagePipeline

    init(dependencies: FeedFeatureBuilder.Dependencies) {
        imagePipeline = dependencies.imagePipeline
    }
}
