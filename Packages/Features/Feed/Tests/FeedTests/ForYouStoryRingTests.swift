import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The unseen-story ring of For You's friends row (#1169): the signature,
/// violet → mint (#2282; #2089 had its own raspberry → violet), along the
/// brand's diagonal, in both appearances — its mint end deepened under
/// Increased Contrast.
@MainActor
struct ForYouStoryRingTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theRingWearsTheSignature(_ style: UIUserInterfaceStyle) {
        let cell = ForYouStoryCell(frame: CGRect(x: 0, y: 0, width: 80, height: 100))
        cell.overrideUserInterfaceStyle = style
        cell.layoutIfNeeded()
        let ring = cell.debugRingGradient
        let resolving = UITraitCollection(userInterfaceStyle: style)
        #expect(ring.colors == Palette.storyRingGradient.map { $0.resolvedColor(with: resolving).cgColor })
        #expect(ring.colors.map(Self.hex) == [0x7235FF, 0x16FFCB], "not the signature, violet → mint")
        #expect(ring.locations == [0, 1])
        #expect(ring.start == Palette.brandGradientStart && ring.end == Palette.brandGradientEnd)
    }

    /// Increased Contrast (#2282, as the loader's): the mint end deepened
    /// to reach 3:1 on the light page.
    @Test func increasedContrastDeepensTheMintEnd() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let cell = ForYouStoryCell(frame: CGRect(x: 0, y: 0, width: 80, height: 100))
        window.addSubview(cell)
        window.isHidden = false
        defer { window.isHidden = true }
        cell.traitOverrides.accessibilityContrast = .high
        cell.layoutIfNeeded()
        #expect(cell.debugRingGradient.colors.map(Self.hex) == [0x7235FF, 0x009E7B])
    }

    private static func hex(_ color: CGColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(cgColor: color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }
}
