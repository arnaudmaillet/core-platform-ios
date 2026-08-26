import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// Does the carousel agree with itself about which page it is on?
@MainActor
struct LastPageProbeTests {
    @Test func theLastPageResolvesToItself() {
        for style in [MediaCarouselView.Style.card, .page] {
            let view = MediaCarouselView(
                style: style, frame: CGRect(x: 0, y: 0, width: 358, height: 240)
            )
            let pages = (0..<4).map { index in
                GalleryPost.MediaPage(
                    thumbnailURL: URL(string: "mock://t/\(index)"),
                    videoURL: URL(string: "mock://video/\(index)")
                )
            }
            view.configure(
                with: pages,
                imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
            )
            view.layoutIfNeeded()
            for target in 0..<4 {
                view.setPage(target, animated: false)
                print("STYLE \(style) asked=\(target) resolved=\(view.currentPage)")
                #expect(view.currentPage == target)
            }
        }
    }
}
