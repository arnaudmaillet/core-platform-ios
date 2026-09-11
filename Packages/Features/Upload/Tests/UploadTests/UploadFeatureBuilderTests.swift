import Testing
import UIKit
@testable import Upload

@MainActor
struct UploadFeatureBuilderTests {
    /// Each "+" entry lands on a screen of its own, and each one can be closed
    /// from a control — a sheet whose only way out is a swipe nobody is told
    /// about is a trap, however empty it is.
    @Test func eachEntryIsItsOwnClosableScreen() throws {
        let builder = UploadFeatureBuilder()
        let screens = [builder.makeMediaUploadViewController(), builder.makeTextPostViewController()]
        let roots = try screens.map { try #require(($0 as? UINavigationController)?.viewControllers.first) }

        #expect(roots.map(\.title) == ["Upload Media", "Text Post"])
        #expect(roots.allSatisfy { $0.navigationItem.leftBarButtonItem != nil })
    }
}
