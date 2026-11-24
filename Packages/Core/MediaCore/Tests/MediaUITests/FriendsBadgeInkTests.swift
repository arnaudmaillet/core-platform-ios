import DesignSystem
import Testing
import UIKit
@testable import MediaCore
@testable import MediaUI

/// Friends' badge is a dark grey disc with a mint glyph (#2440; dark grey,
/// not black, since #2476, the owner 2026-11-17): `48484A` in the light,
/// `3A3A3C` in the dark, and `3A3A3C` in the light with Increased Contrast.
/// Following keeps its grey disc and pink check.
@MainActor
struct FriendsBadgeInkTests {
    private static func hex(_ color: UIColor, _ style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast = .normal) -> String {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    @Test(arguments: [UIAccessibilityContrast.normal, .high])
    func friendsIsADarkGreyDiscWithAMintGlyph(_ contrast: UIAccessibilityContrast) {
        let disc = RelationBadgeView.discInk(for: .friends)
        let glyph = RelationBadgeView.glyphInk(for: .friends)
        #expect(Self.hex(disc, .light, contrast: contrast) == (contrast == .high ? "3A3A3C" : "48484A"), "dark grey, not black")
        #expect(Self.hex(disc, .dark, contrast: contrast) == "3A3A3C", "a step lighter than the black page, so the disc keeps its outline")
        #expect(Self.hex(glyph, .light, contrast: contrast) == "16FFCB")
        #expect(Self.hex(glyph, .dark, contrast: contrast) == "16FFCB")
    }

    /// Following is unchanged: the avatar's grey ground under the primary's
    /// light value.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func followingKeepsItsGreyDiscAndPinkCheck(_ style: UIUserInterfaceStyle) {
        #expect(Self.hex(RelationBadgeView.discInk(for: .following), style) == Self.hex(Surface.avatarGround, style))
        #expect(Self.hex(RelationBadgeView.glyphInk(for: .following), style) == "FF1358")
    }

    /// The two relations no longer share the primary: told apart at a glance.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func friendsAndFollowingWearNoInkInCommon(_ style: UIUserInterfaceStyle) {
        let friends = [RelationBadgeView.discInk(for: .friends), RelationBadgeView.glyphInk(for: .friends)].map { Self.hex($0, style) }
        let following = [RelationBadgeView.discInk(for: .following), RelationBadgeView.glyphInk(for: .following)].map { Self.hex($0, style) }
        #expect(Set(friends).isDisjoint(with: following))
    }
}
