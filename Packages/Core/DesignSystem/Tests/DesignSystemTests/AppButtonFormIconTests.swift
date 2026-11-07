import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The sign-in sheet's needs (#2020): a form size at its host's width, an
/// icon that is a symbol or an image in its own colours, and Sign in with
/// Apple's monochrome ground.
@MainActor
struct AppButtonFormIconTests {
    private static let logo: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { _ in
        UIColor.systemRed.setFill()
        UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 60, height: 60)).fill()
    }

    private func hosted(_ button: AppButton, width: CGFloat = 360) -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 120))
        window.addSubview(host)
        button.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        host.layoutIfNeeded()
        return (window, host)
    }

    // MARK: - The form size

    /// The system large button's height at the default size, and the width
    /// its host gives — not its words'.
    @Test func theFormSizeTakesTheHostsWidthAtTheLargeButtonsHeight() {
        let button = AppButton(aspect: .pill(.prominent), size: .form, content: .title("Continue"))
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        #expect(abs(button.bounds.width - host.bounds.width) < 0.5, "\(button.bounds.width) in \(host.bounds.width)")
        let expected = 2 * AppButton.formVerticalInset + AppButton.font(for: .form).lineHeight
        #expect(abs(button.bounds.height - expected) <= 2, "\(button.bounds.height) against \(expected)")
        #expect(button.bounds.height >= 48 && button.bounds.height <= 54, "not the large button's height: \(button.bounds.height)")
    }

    /// Its words grow with the text size, up to the app's ceiling.
    @Test func theFormSizeGrowsWithTheTextSize() {
        let base = AppButton.font(for: .form, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let large = AppButton.font(
            for: .form, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        #expect(large.pointSize > base.pointSize, "\(large.pointSize) vs \(base.pointSize)")
    }

    // MARK: - Icons

    @Test func aSymbolContentIsUnchanged() {
        let content = AppButton.Content(title: "Message", symbol: "paperplane")
        #expect(content.symbol == "paperplane")
        #expect(content.icon == .symbol("paperplane"))
        var changed = content
        changed.symbol = "checkmark"
        #expect(changed.icon == .symbol("checkmark"))
        let button = AppButton(aspect: .pill(.quiet), size: .header, content: content)
        #expect(button.configuration?.image?.isSymbolImage == true)
        #expect(button.configuration?.image?.renderingMode != .alwaysOriginal)
    }

    /// An image is drawn in its own colours — never tinted — at the
    /// symbol's height, in the symbol's place, on every ground.
    @Test(arguments: [AppButton.Ground.prominent, .quiet, .tinted, .material, .monochrome])
    func anImageIconIsUntintedAtTheSymbolsSize(_ ground: AppButton.Ground) throws {
        let content = AppButton.Content(title: "Continue with Google", icon: .image(Self.logo), imagePlacement: .leading)
        let button = AppButton(aspect: .pill(ground), size: .form, shape: .card, content: content)
        let image = try #require(button.configuration?.image)
        #expect(image.renderingMode == .alwaysOriginal, "the logo would be tinted with the ink")
        #expect(!image.isSymbolImage)
        let side = AppButton.imageIconSide(for: AppButton.font(for: .form))
        #expect(abs(image.size.height - side) < 0.5, "\(image.size) against the symbol's \(side)")
        #expect(button.configuration?.imagePlacement == .leading)
        #expect(content.symbol == nil)
    }

    /// The image keeps its colours through a content change and a load, and
    /// the large-content viewer shows it.
    @Test func anImageIconSurvivesAChangeAndALoad() async throws {
        let button = AppButton(aspect: .pill(.quiet), size: .form, content: .title("Continue"))
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setContent(AppButton.Content(title: "Continue with Google", icon: .image(Self.logo)), animated: true)
        #expect(button.configuration?.image?.renderingMode == .alwaysOriginal)
        button.setPhase(.loading, animated: true)
        #expect(button.phase == .loading)
        #expect(button.configuration?.image?.renderingMode == .alwaysOriginal, "the load dropped or tinted the logo")
        #expect(button.largeContentImage != nil, "the large-content viewer has no icon")
        button.setPhase(.content, animated: false)
        #expect(button.configuration?.image?.renderingMode == .alwaysOriginal)
    }

    // MARK: - The monochrome ground

    /// Black in the light, white in the dark, the ink the other way round:
    /// Sign in with Apple's grounds.
    @Test func theMonochromeGroundIsBlackOrWhite() throws {
        let button = AppButton(aspect: .pill(.monochrome), size: .form, shape: .card, content: AppButton.Content(title: "Continue with Apple", symbol: "apple.logo"))
        let fill = try #require(button.configuration?.baseBackgroundColor)
        let ink = try #require(button.configuration?.baseForegroundColor)
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        func white(_ colour: UIColor, _ traits: UITraitCollection) -> CGFloat {
            var w: CGFloat = 0
            colour.resolvedColor(with: traits).getWhite(&w, alpha: nil)
            return w
        }
        #expect(white(fill, light) < 0.05 && white(fill, dark) > 0.95, "not black / white")
        #expect(white(ink, light) > 0.95 && white(ink, dark) < 0.05, "the ink does not invert")
        #expect(button.currentGround == .monochrome)
        button.isSelected = true
        #expect(button.currentGround == .monochrome, "selection changed Apple's ground")
    }
}
