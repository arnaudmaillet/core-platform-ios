import Testing
import UIKit
@testable import DesignSystem

/// ONE AVATAR GROUND, LIGHT (#2051, the owner 2026-11-02): "an avatar's
/// ground is always the light grey, whatever the device's appearance. The
/// dark grey must not exist." The same person wore a light disc in one bar
/// and a dark one in the next, because the plate resolved against whichever
/// traits it was drawn under.
@MainActor
struct AvatarGroundTests {
    private static let light = UITraitCollection(userInterfaceStyle: .light)
    private static let dark = UITraitCollection(userInterfaceStyle: .dark)

    /// The tokens are the light appearance's values, the same in a dark
    /// trait collection.
    @Test func theTokensAreTheLightValues() {
        let pairs: [(UIColor, UIColor)] = [
            (Surface.avatarGround, .systemGray5),
            (Surface.avatarInitialsGround, .systemGray4),
            (Surface.avatarInitials, .secondaryLabel)
        ]
        for (token, system) in pairs {
            let expected = system.resolvedColor(with: Self.light).cgColor
            #expect(token.resolvedColor(with: Self.light).cgColor == expected)
            #expect(token.resolvedColor(with: Self.dark).cgColor == expected)
        }
        #expect(MonogramAvatarView.plateColor == Surface.avatarGround)
        #expect(MonogramAvatarView.initialsPlateColor == Surface.avatarInitialsGround)
    }

    /// The final initials stay a step darker than the loading floor (#1912).
    @Test func theFinalGreyIsApartFromTheLoadingGrey() {
        #expect(Surface.avatarInitialsGround.cgColor != Surface.avatarGround.cgColor)
    }

    /// The drawn plate and the initials' ink are the same under a light and
    /// a dark appearance, loading and final.
    @Test(arguments: [false, true])
    func thePlateIsTheSameInBothAppearances(final: Bool) {
        let expected = (final ? Surface.avatarInitialsGround : Surface.avatarGround).cgColor
        var plates: [CGColor] = []
        var inks: [CGColor] = []
        for style in [UIUserInterfaceStyle.light, .dark] {
            let monogram = MonogramAvatarView(diameter: 36)
            monogram.overrideUserInterfaceStyle = style
            monogram.setMonogram("MH")
            monogram.showsFinalInitials = final
            monogram.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
            monogram.layoutIfNeeded()
            plates.append(monogram.drawnPlateColor.cgColor)
            inks.append((monogram.drawnInitialsColor ?? .clear).resolvedColor(with: monogram.traitCollection).cgColor)
        }
        #expect(plates.allSatisfy { $0 == expected }, "the plate changed with the appearance")
        #expect(inks[0] == inks[1], "the initials changed with the appearance")
        #expect(inks[0] == Surface.avatarInitials.cgColor)
    }

    /// ⚠️ THE INITIALS ARE NO LABEL: inside a glass bar item UIKit draws a
    /// label as vibrant content, and the dark ink came out a light grey on
    /// the light plate. A layer's bitmap is drawn as it is.
    @Test func theInitialsAreABitmapNotALabel() {
        let monogram = MonogramAvatarView(diameter: 36)
        monogram.setMonogram("MH")
        #expect(monogram.subviews.compactMap { $0 as? UILabel }.isEmpty, "a label draws the initials")
        #expect(monogram.initials.contents != nil)
        #expect(monogram.debugMonogramText == "MH")
        monogram.setMonogram("")
        #expect(monogram.initials.contents == nil)
    }

    /// A style change on screen redraws nothing: the plate keeps its grey.
    @Test func aTraitChangeLeavesThePlate() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.overrideUserInterfaceStyle = .light
        let monogram = MonogramAvatarView(diameter: 36)
        window.addSubview(monogram)
        window.isHidden = false
        defer { window.isHidden = true }
        monogram.layoutIfNeeded()
        let before = monogram.drawnPlateColor.cgColor
        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        monogram.layoutIfNeeded()
        #expect(monogram.traitCollection.userInterfaceStyle == .dark)
        #expect(monogram.drawnPlateColor.cgColor == before)
        #expect(before == Surface.avatarGround.cgColor)
    }

    /// The avatar's bone wears the same fixed grey, so two greys never meet
    /// under a loading face — in a dark appearance too.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theBoneWearsTheAvatarsGround(_ style: UIUserInterfaceStyle) {
        let skeleton = AvatarSkeletonView(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        skeleton.overrideUserInterfaceStyle = style
        skeleton.layoutIfNeeded()
        #expect(skeleton.drawnGround == Surface.avatarGround.cgColor)
    }
}
