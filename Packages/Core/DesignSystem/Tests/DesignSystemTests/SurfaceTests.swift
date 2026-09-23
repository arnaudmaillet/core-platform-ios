import Testing
import UIKit
@testable import DesignSystem

/// The tone system a screen of cards is built from — see `Surface`.
@MainActor
struct SurfaceTests {
    private let light = UITraitCollection(userInterfaceStyle: .light)
    private let dark = UITraitCollection(userInterfaceStyle: .dark)

    /// The premise: a card is LIGHTER than its page in the light — that is the
    /// whole elevation — and the pair is the system's grouped one, not a
    /// bespoke colour that would stop tracking elevation and accessibility.
    @Test func theCardIsLighterThanThePageInTheLight() {
        #expect(luminance(Surface.page, light) < luminance(Surface.card, light))
        #expect(Surface.page.resolvedColor(with: light) == UIColor.systemGroupedBackground.resolvedColor(with: light))
        #expect(Surface.card.resolvedColor(with: light) == UIColor.secondarySystemGroupedBackground.resolvedColor(with: light))
    }

    /// Moving to grouped tokens changed nothing in the dark: the pair is
    /// byte-identical to the plain background pair there.
    @Test func theDarkSideIsUnchanged() {
        #expect(Surface.page.resolvedColor(with: dark) == UIColor.systemBackground.resolvedColor(with: dark))
        #expect(Surface.card.resolvedColor(with: dark) == UIColor.secondarySystemBackground.resolvedColor(with: dark))
    }

    /// The edge exists only where tone cannot do the job.
    @Test func theEdgeIsClearInTheLightAndDrawnInTheDark() {
        #expect(Surface.cardEdge.resolvedColor(with: light).cgColor.alpha == 0)
        #expect(Surface.cardEdge.resolvedColor(with: dark).cgColor.alpha > 0)
    }

    /// One device pixel, not one point: at 3x that is a third of a point.
    @Test func theHairlineIsOneDevicePixel() {
        #expect(abs(Surface.hairline(for: UITraitCollection(displayScale: 3)) - 1 / 3) < 0.0001)
        #expect(Surface.hairline(for: UITraitCollection(displayScale: 2)) == 0.5)
        #expect(Surface.hairline(for: UITraitCollection(displayScale: 0)) == 1)
    }

    /// A dressed view carries the edge, and re-resolves it when its style
    /// flips — a CGColor does not track traits by itself.
    @Test func aDressedViewFollowsTheStyle() {
        // In a window, because traits only propagate — and trait-change
        // handlers only fire — for a view that is part of a hierarchy UIKit
        // lays out.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.overrideUserInterfaceStyle = .dark
        let card = UIView(frame: window.bounds)
        window.addSubview(card)
        window.isHidden = false
        window.layoutIfNeeded()
        Surface.applyCardEdge(to: card)
        #expect(card.layer.borderWidth > 0)
        #expect(card.layer.borderWidth <= 0.5)
        #expect(card.layer.borderColor?.alpha ?? 0 > 0)

        window.overrideUserInterfaceStyle = .light
        window.layoutIfNeeded()
        #expect(card.layer.borderColor?.alpha == 0)
        window.isHidden = true
    }

    private func luminance(_ color: UIColor, _ traits: UITraitCollection) -> CGFloat {
        var white: CGFloat = 0
        color.resolvedColor(with: traits).getWhite(&white, alpha: nil)
        return white
    }
}
