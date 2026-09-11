import Testing
import UIKit
@testable import DesignSystem

/// The platter contract, as numbers: the path IS the view's bounds, and the
/// fill travels in the parameters.
@MainActor
@Suite("Lifted preview")
struct LiftedPreviewTests {
    @Test("The visible path's bounds are exactly the bounds it was given")
    func pathCoincidesWithTheBounds() throws {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 64)
        let parameters = LiftedPreview.parameters(for: bounds, cornerRadius: 14, platterColor: .systemBackground)
        let path = try #require(parameters.visiblePath)
        #expect(path.bounds == bounds)
    }

    @Test("The fill is the platter's colour")
    func fillTravelsInTheParameters() {
        let parameters = LiftedPreview.parameters(
            for: CGRect(x: 0, y: 0, width: 200, height: 50), cornerRadius: 10, platterColor: .systemBackground
        )
        #expect(parameters.backgroundColor == .systemBackground)
    }

    /// The initializer this uses requires the view to be in a window — which a
    /// realized row always is — so the plate is given one here.
    @Test("A targeted lift uses the view's own bounds and leaves its background alone")
    func targetedLiftUsesTheView() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let plate = UIView(frame: CGRect(x: 12, y: 40, width: 300, height: 64))
        plate.backgroundColor = .clear
        window.addSubview(plate)
        window.isHidden = false

        let preview = LiftedPreview.targeted(view: plate, cornerRadius: 14, platterColor: .systemBackground)
        let path = try #require(preview.parameters.visiblePath)
        #expect(preview.view === plate)
        #expect(path.bounds == plate.bounds)
        #expect(plate.backgroundColor == .clear)
    }
}
