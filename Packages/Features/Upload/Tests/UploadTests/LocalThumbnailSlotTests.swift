import DesignSystem
import Testing
import UIKit
@testable import Upload

/// A local picture's place (#1772): the media ground while it decodes, the
/// picture for its own item only.
@MainActor
struct LocalThumbnailSlotTests {
    private let picture = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }

    @Test func itWaitsOnTheGroundAndTakesOnlyItsOwnPicture() {
        let view = UIImageView()
        let slot = LocalThumbnailSlot(view: view)
        #expect(view.backgroundColor == Surface.mediaGround)
        slot.begin("a")
        slot.show(picture, for: "b")
        #expect(view.image == nil, "another item's picture landed")
        slot.show(picture, for: "a")
        #expect(view.image === picture)
        slot.begin("a")
        #expect(view.image === picture, "a reconfigure of the same item emptied it")
        slot.reset()
        #expect(view.image == nil)
        slot.show(picture, for: "a")
        #expect(view.image == nil, "a picture landed on a recycled place")
    }

    @Test func aHostKeepsItsOwnCanvas() {
        let view = UIImageView()
        _ = LocalThumbnailSlot(view: view, ground: .black)
        #expect(view.backgroundColor == .black)
    }
}
