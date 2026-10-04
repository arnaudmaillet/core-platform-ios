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
        #expect(!monogram.plate.isHidden && !label.isHidden)
        monogram.isCovered = true
        #expect(monogram.plate.isHidden && label.isHidden)
        monogram.isCovered = false
        #expect(!monogram.plate.isHidden && !label.isHidden)
    }

    /// The plate is an oval PATH with a plain resolved colour, never the view's
    /// background: a system fill as a background is painted by a `_UIMultiLayer`
    /// inside a glass bar item, and a bar transition drew that as a rounded
    /// square. Round from birth — before any layout pass — too.
    @Test func thePlateIsAnOvalPathNotABackground() throws {
        let monogram = MonogramAvatarView(diameter: 32)
        #expect(monogram.backgroundColor == nil)
        #expect(monogram.layer.backgroundColor == nil)
        let birth = try #require(monogram.plate.path)
        #expect(birth == UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 32, height: 32)).cgPath)
        #expect(monogram.plate.fillColor != nil)

        monogram.setDiameter(40)
        monogram.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        monogram.layoutIfNeeded()
        #expect(monogram.plate.path == UIBezierPath(ovalIn: monogram.bounds).cgPath)
        #expect(monogram.plate.frame == monogram.bounds)
    }

    /// A surface that asks for the super-ellipse gets it everywhere at once —
    /// mask and plate — and wears the matching circular corner underneath, the
    /// one a flight's layer can carry.
    @Test func aSuperellipseShapesMaskPlateAndCorner() throws {
        let shape = AvatarShape.superellipse(exponent: 2.6)
        let monogram = MonogramAvatarView(diameter: 50)
        monogram.shape = shape
        let picture = AvatarImageView()
        picture.shape = shape
        let bounds = CGRect(x: 0, y: 0, width: 50, height: 50)
        let expected = shape.path(in: bounds).cgPath
        for view in [monogram, picture] as [UIView] {
            view.frame = bounds
            view.layoutIfNeeded()
            let mask = try #require(view.layer.mask as? CAShapeLayer, "\(type(of: view)) has no mask")
            #expect(mask.path == expected)
            #expect(view.layer.cornerRadius == shape.cornerRadius(side: 50))
            #expect(view.layer.cornerCurve == .circular)
        }
        #expect(monogram.plate.path == expected)
        // Not a disc: a point just past the circle's corner is inside.
        #expect(expected.contains(CGPoint(x: 7, y: 7)))
        #expect(!UIBezierPath(ovalIn: bounds).cgPath.contains(CGPoint(x: 7, y: 7)))
    }

    /// The flight's stand-in corner meets the super-ellipse on the diagonal:
    /// an arc of that radius reaches the outline's own diagonal point.
    @Test func theSuperellipseCornerMatchesOnTheDiagonal() {
        let exponent: CGFloat = 2.6
        let side: CGFloat = 60
        let radius = AvatarShape.superellipse(exponent: exponent).cornerRadius(side: side)
        // Both diagonal points, as their offset from the centre on each axis.
        let arc = (side / 2 - radius) + radius / 2.squareRoot()
        let outline = side / 2 * pow(2, -1 / exponent)
        #expect(abs(arc - outline) < 0.01)
        #expect(AvatarShape.circle.cornerRadius(side: side) == 30)
    }
}
