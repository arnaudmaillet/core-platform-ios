import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The app's icon-only button (#1666): a 44pt bubble or a bare glyph with
/// its count — the grounds, the symbol's motions, the press (a swell, as
/// the pills'), the card actions' wash, hold and menu.
@MainActor
struct AppIconButtonTests {
    private func hosted(_ button: AppControl) -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 80))
        window.addSubview(host)
        button.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            button.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        host.layoutIfNeeded()
        return (window, host)
    }

    private func glyph(_ content: AppIconButton.Content, dims: Bool? = nil) -> AppIconButton {
        AppIconButton(style: .glyph, content: content, dims: dims)
    }

    // MARK: - Styles

    @Test(arguments: [AppControl.Ground.prominent, .quiet, .tinted, .material])
    func everyBubbleIsA44PointCircleOnItsGround(_ ground: AppControl.Ground) {
        let button = AppIconButton(style: .bubble(ground), content: .symbol("qrcode"))
        #expect(button.currentGround == ground)
        #expect(button.debugMaterialIsShown == (ground == .material), "only the material bubble wears a blur")
        #expect(button.configuration?.title == nil)
        #expect(button.intrinsicContentSize == CGSize(width: 44, height: 44))
        #expect(button.fittingSize(for: .symbol("qrcode")) == CGSize(width: 44, height: 44))
    }

    @Test func aGlyphHasNoGroundUntilButtonShapesAsksForOne() {
        let button = glyph(AppIconButton.Content(symbol: "heart", count: 12))
        button.buttonShapes = { false }
        #expect(button.currentGround == nil)
        #expect(button.configuration?.background.backgroundColor == nil || button.configuration?.background.backgroundColor == .clear)
        button.buttonShapes = { true }
        #expect(button.currentGround == .quiet, "Button Shapes on: the glyph gains a visible shape")
    }

    @Test func aCountIsDrawnCompactBesideTheSymbol() {
        let button = glyph(AppIconButton.Content(symbol: "heart", count: 1_234))
        #expect(button.configuration?.image != nil)
        #expect(button.configuration?.title == "1.2K", "a count is drawn compact")
        #expect(button.accessibilityValue == "1234", "the count is the accessibility value")
    }

    @Test func aGlyphTakesAFingerOver44Points() {
        let button = glyph(.symbol("xmark"))
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        host.layoutIfNeeded()
        let region = button.hitRegion
        #expect(region.width >= 44 && region.height >= 44, "\(region)")
        #expect(button.point(inside: CGPoint(x: region.minX + 1, y: region.minY + 1), with: nil))
    }

    /// Selected, the symbol takes its tint; the count keeps the ink, and a
    /// glyph grows no ground.
    @Test func selectedTintsTheSymbolNotTheCount() {
        let liked = glyph(.symbol("heart"))
        liked.selectedTint = .systemRed
        liked.isSelected = true
        #expect(liked.configuration?.imageColorTransformer?(.label) == .systemRed)
        #expect(liked.configuration?.baseForegroundColor == .label)
        let ground = liked.configuration?.updated(for: liked).background.resolvedBackgroundColor(for: .systemBlue)
        #expect(ground == .clear, "a selected glyph grew a ground: \(String(describing: ground))")
    }

    // MARK: - Motion, and each fallback

    @Test(arguments: [false, true])
    func aCountRollsOrFades(_ reduced: Bool) {
        let button = glyph(AppIconButton.Content(symbol: "heart", count: 9))
        button.reducesMotion = { reduced }
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setContent(AppIconButton.Content(symbol: "heart", count: 10), animated: true)
        #expect(button.events.last == (reduced ? .countFade : .countRoll(up: true)))
        button.setContent(AppIconButton.Content(symbol: "heart", count: 8), animated: true)
        #expect(button.events.last == (reduced ? .countFade : .countRoll(up: false)))
        #expect(button.configuration?.title == "8")
        #expect(button.accessibilityValue == "8")
    }

    /// A like is a new symbol AND a new count: the count rolls, and the same
    /// refresh replaces the symbol — never a blur, which is for words.
    @Test func aLikeRollsTheCountAndReplacesTheSymbol() {
        let button = glyph(AppIconButton.Content(symbol: "heart", count: 9))
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setContent(AppIconButton.Content(symbol: "heart.fill", count: 10), animated: true)
        #expect(button.events.last == .countRoll(up: true))
        #expect(button.content.symbol == "heart.fill")
        #expect(!button.events.contains(.blurMorph))
    }

    @Test(arguments: [false, true])
    func aSymbolSwapIsReplacedOrFaded(_ reduced: Bool) {
        let button = glyph(.symbol("bookmark"))
        button.reducesMotion = { reduced }
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setContent(.symbol("bookmark.fill"), animated: true)
        #expect(button.events.last == (reduced ? .symbolFade : .symbolReplace))
    }

    @Test(arguments: [false, true])
    func theSymbolEffectBouncesOrFlashes(_ reduced: Bool) {
        let button = glyph(.symbol("heart"))
        button.reducesMotion = { reduced }
        button.bouncesSymbolOnTap = true
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.updateConfiguration()
        button.layoutIfNeeded()
        button.debugTap()
        #expect(button.events.last == (reduced ? .symbolFlash : .symbolBounce))
    }

    @Test func selectingCrossFadesTheTint() {
        let button = glyph(.symbol("heart"))
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setSelected(true, animated: true)
        #expect(button.events.last == .stateTint)
        #expect(button.isSelected)
    }

    @Test func aSuccessCanChangeTheSymbol() {
        let button = glyph(.symbol("bookmark"))
        button.notifiesCompletion = true
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.succeed(showing: "checkmark")
        #expect(button.content.symbol == "checkmark")
        #expect(button.events.contains(.notification(success: true)))
    }

    @Test func appearAndGoAreTheSharedMotions() {
        let button = AppIconButton(style: .bubble(.quiet), content: .symbol("ellipsis"))
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.disappear(animated: true)
        #expect(button.isHidden)
        #expect(button.events.last == .scaleOut)
        button.appear(animated: true)
        #expect(!button.isHidden)
        #expect(button.events.last == .bounceIn)
    }

    // MARK: - Press

    /// Both styles swell under the finger, as the pills do (the owner,
    /// 2026-10-24) — as a circle, never an ellipse.
    @Test(arguments: [AppIconButton.Style.glyph, .bubble(.quiet)])
    func bothStylesSwellAsACircle(_ style: AppIconButton.Style) throws {
        let button = AppIconButton(style: style, content: .symbol("heart"))
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        let press = try #require(button.pressFeedback)
        #expect(press.style == .swell)
        button.sendActions(for: .touchDown)
        #expect(press.scale > 1, "\(style) gave under the finger instead of swelling")
        let swelled = PressFeedback.swelledScale(for: button.bounds.size)
        #expect(swelled.x <= swelled.y, "a square swelled wider than tall: \(swelled)")
    }

    @Test func aGlyphDimsAndABubbleDoesNotByDefault() throws {
        let glyph = AppIconButton(style: .glyph, content: .symbol("xmark"))
        let bubble = AppIconButton(style: .bubble(.quiet), content: .symbol("xmark"))
        let (window, _) = hosted(glyph)
        defer { window.isHidden = true }
        glyph.sendActions(for: .touchDown)
        #expect(try #require(glyph.pressFeedback).debugIsDimmedOnTheLayer)
        bubble.sendActions(for: .touchDown)
        #expect(try #require(bubble.pressFeedback).debugIsDimmedOnTheLayer == false)
    }

    // MARK: - The card actions' press (#934)

    /// A card action: no dim, a wash inside its shape — one step pressed, a
    /// second held — gone once the finger lifts; a lift inside still taps.
    @Test func aCardActionWashesInsteadOfDimming() {
        let button = glyph(.init(symbol: "heart", count: 3), dims: false)
        button.washesOnPress = true
        button.holdFreezesScrolling = true
        var tapped = 0
        button.addAction(UIAction { _ in tapped += 1 }, for: .primaryActionTriggered)
        #expect(button.debugWashAlpha == 0)
        button.debugHold(liftInside: true)
        #expect(tapped == 1)
        #expect(button.debugWashAlpha == 0, "the wash clears after the hold")
        #expect(!button.isHolding)
        button.debugHold(liftInside: false)
        #expect(tapped == 1, "a lift outside does not tap")
        #expect(AppControl.Metrics.pressedWash < AppControl.Metrics.heldWash)
    }

    /// The hold shares the finger with the button's own recognisers (its
    /// menu's) and with nothing above it.
    @Test func theHoldSharesOnlyWithTheButtonsOwnRecognisers() throws {
        let host = UIScrollView()
        let button = glyph(.symbol("heart"))
        host.addSubview(button)
        button.holdFreezesScrolling = true
        let hold = try #require(button.debugHoldRecognizer)
        let own = UILongPressGestureRecognizer()
        button.addGestureRecognizer(own)
        let delegate = try #require(hold.delegate)
        #expect(delegate.gestureRecognizer?(hold, shouldRecognizeSimultaneouslyWith: own) == true)
        #expect(delegate.gestureRecognizer?(hold, shouldRecognizeSimultaneouslyWith: host.panGestureRecognizer) == false)
    }

    /// A held card action raises its menu — built when it lifts — and a
    /// button without one keeps UIKit's own context menu off.
    @Test func aMenuProviderTurnsTheHoldMenuOn() throws {
        let button = glyph(.symbol("heart"))
        #expect(!button.isContextMenuInteractionEnabled)
        var built = 0
        button.menuProvider = {
            built += 1
            return UIMenu(children: [UIAction(title: "Stake 50") { _ in }])
        }
        #expect(button.isContextMenuInteractionEnabled)
        #expect(built == 0, "built when raised, not when set")
        let interaction = try #require(button.contextMenuInteraction)
        let configuration = try #require(button.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero))
        _ = configuration
        button.menuProvider = nil
        #expect(!button.isContextMenuInteractionEnabled)
    }

    /// A provider that answers nil raises nothing — not a lifted preview
    /// round an empty menu (a guest's like, #1146).
    @Test func aProviderThatAnswersNilRaisesNothing() throws {
        let button = glyph(.symbol("heart"))
        button.menuProvider = { nil }
        let interaction = try #require(button.contextMenuInteraction)
        #expect(button.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero) == nil)
    }

    /// A card's glyph is drawn at its own size, not the style's.
    @Test func aSymbolPointSizeOverridesTheStyles() throws {
        let button = glyph(.symbol("heart"))
        button.symbolPointSize = 17
        let symbol = try #require(button.configuration?.preferredSymbolConfigurationForImage)
        #expect(symbol == UIImage.SymbolConfiguration(pointSize: 17, weight: .medium, scale: .medium))
    }

    @Test func aMenuIsUIKitsAndAnIconShowsLarge() {
        let button = AppIconButton(style: .bubble(.quiet), content: .symbol("ellipsis"))
        button.menu = UIMenu(children: [UIAction(title: "Report") { _ in }])
        button.showsMenuAsPrimaryAction = true
        #expect(button.showsMenuAsPrimaryAction)
        #expect(button.showsLargeContentViewer, "an icon-only button shows large on a long press")
    }
}
