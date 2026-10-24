import Testing
import UIKit
@testable import DesignSystem

/// Under a press an `AppIconButton`'s icon scales with its text, by
/// `PressFeedback`'s factor alone (#1376). UIKit's symbol animation shrank the
/// icon to about half on every highlight — measured, 11.7 pt to 6.3 pt — so it
/// stays off, and the symbol replace comes from the configuration.
@MainActor
@Suite(.serialized)
struct AppButtonIconPressTests {
    /// Every layer under the image view, presentation values.
    private func symbolExtents(in layer: CALayer) -> [CGSize] {
        let shown = layer.presentation() ?? layer
        return [shown.bounds.size] + (layer.sublayers ?? []).flatMap(symbolExtents(in:))
    }

    @Test func symbolAnimationIsOff() {
        let button = AppIconButton(style: .glyph, content: AppIconButton.Content(symbol: "bubble", count: 78))
        #expect(button.isSymbolAnimationEnabled == false)
    }

    /// Held, nothing inside the image view draws smaller than it did at rest.
    /// Async: UIKit's shrink ran over a few hundred ms. No global state.
    @Test func aHighlightLeavesTheIconItsSize() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let button = AppIconButton(style: .glyph, content: AppIconButton.Content(symbol: "bubble", count: 78))
        host.view.addSubview(button)
        button.frame = CGRect(x: 100, y: 100, width: 80, height: 36)
        button.layoutIfNeeded()
        let image = try #require(button.imageView)
        let rest = image.bounds.size

        button.isHighlighted = true
        button.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))

        for extent in symbolExtents(in: image.layer) where extent != .zero {
            #expect(extent.width >= rest.width * 0.7, "the icon shrank on its own: \(extent) of \(rest)")
        }
        button.isHighlighted = false
    }

    /// A symbol swapped for another is still replaced — the configuration's
    /// transition — and simply swapped under reduced motion (the cross-fade).
    @Test func theSymbolReplaceComesFromTheConfiguration() {
        let button = AppIconButton(style: .bubble(.quiet), content: .symbol("star"))
        button.reducesMotion = { false }
        #expect(button.configuration(for: .symbol("star.fill")).symbolContentTransition != nil)
        button.reducesMotion = { true }
        #expect(button.configuration(for: .symbol("star.fill")).symbolContentTransition == nil)
    }
}
