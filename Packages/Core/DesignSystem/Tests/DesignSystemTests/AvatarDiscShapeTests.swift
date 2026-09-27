import Testing
import UIKit
@testable import DesignSystem

/// An avatar is a DISC whatever its container does to corners, and a picture
/// covers the initials plate entirely.
@MainActor
struct AvatarDiscShapeTests {
    /// The disc is an oval mask over the whole bounds: a container's corner
    /// configuration reshaped `cornerRadius` into a squircle on a device.
    @Test func bothDiscsAreMaskedToACircle() throws {
        let monogram = MonogramAvatarView(diameter: 32)
        let picture = AvatarImageView()
        for view in [monogram, picture] as [UIView] {
            view.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            view.layoutIfNeeded()
            let mask = try #require(view.layer.mask as? CAShapeLayer, "\(type(of: view)) has no mask")
            let path = try #require(mask.path)
            #expect(path == UIBezierPath(ovalIn: view.bounds).cgPath)
        }
    }

    /// Covered: no plate and no initials, only the picture shows.
    @Test func aCoveredDiscDrawsNothing() throws {
        let monogram = MonogramAvatarView(diameter: 32)
        monogram.setMonogram("MH")
        let label = try #require(monogram.subviews.compactMap { $0 as? UILabel }.first)
        #expect(monogram.backgroundColor != .clear && !label.isHidden)
        monogram.isCovered = true
        #expect(monogram.backgroundColor == .clear && label.isHidden)
        monogram.isCovered = false
        #expect(monogram.backgroundColor != .clear && !label.isHidden)
    }
}
