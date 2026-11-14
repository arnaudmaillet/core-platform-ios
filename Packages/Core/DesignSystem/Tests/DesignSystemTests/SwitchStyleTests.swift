@testable import DesignSystem
import Testing
import UIKit

/// Every switch turns the primary when on (#2435): one appearance rule at
/// launch, because a `UISwitch` ignores the window's tint.
///
/// ⚠️ An appearance default reaches a view when it moves to a window, so
/// each switch is attached to one before it is read (`ScrollIndicatorStyleTests`).
@MainActor
@Suite("Switch style")
struct SwitchStyleTests {
    private func inWindow(_ view: UISwitch) -> UISwitch {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(view)
        window.isHidden = false
        window.layoutIfNeeded()
        return view
    }

    private func traits(_ style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast = .normal) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        }
    }

    private func hex(_ color: UIColor?, _ traits: UITraitCollection) -> String? {
        guard let resolved = color?.resolvedColor(with: traits) else { return nil }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// A switch made after launch wears the app's tint, in each appearance.
    @Test func aSwitchMadeAfterLaunchTurnsThePrimary() {
        SwitchStyle.tintAppWide()
        let toggle = inWindow(UISwitch())

        for style in [UIUserInterfaceStyle.light, .dark] {
            #expect(hex(toggle.onTintColor, traits(style)) == hex(Palette.tint, traits(style)),
                    "the on track is not the tint in \(style == .light ? "light" : "dark")")
        }
        #expect(hex(toggle.onTintColor, traits(.light)) == "FF1358", "the primary, not iOS's green")
    }

    /// Increased Contrast takes the primary's deeper values: it is the dynamic
    /// tint, not a colour frozen at launch.
    @Test func increasedContrastTakesThePrimarysContrastValues() {
        SwitchStyle.tintAppWide()
        let toggle = inWindow(UISwitch())

        for style in [UIUserInterfaceStyle.light, .dark] {
            let contrast = traits(style, contrast: .high)
            #expect(hex(toggle.onTintColor, contrast) == hex(Palette.tint, contrast))
            #expect(hex(toggle.onTintColor, contrast) != hex(toggle.onTintColor, traits(style)),
                    "Increased Contrast resolves to the same value as the normal one")
        }
    }

    /// A screen that wants another colour still can: an instance value
    /// outranks the appearance default.
    @Test func anExplicitOnTintStillWins() {
        SwitchStyle.tintAppWide()
        let toggle = UISwitch()
        toggle.onTintColor = .systemBlue
        _ = inWindow(toggle)

        #expect(hex(toggle.onTintColor, traits(.light)) == hex(.systemBlue, traits(.light)))
    }
}
