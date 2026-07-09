import MapsInterface
import MediaCore
import UIKit

/// The Maps feature's entry point, resolved by the composition root and
/// consumed through `MapsFeatureBuilding` by the app shell.
@MainActor
public struct MapsFeatureBuilder: MapsFeatureBuilding {
    private let repository: any GeoDiscoveryProviding
    private let imagePipeline: ImagePipeline

    public init(repository: any GeoDiscoveryProviding, imagePipeline: ImagePipeline) {
        self.repository = repository
        self.imagePipeline = imagePipeline
    }

    public func makeMapViewController() -> UIViewController {
        MapsViewController(
            viewModel: MapsViewModel(repository: repository),
            imagePipeline: imagePipeline
        )
    }
}
