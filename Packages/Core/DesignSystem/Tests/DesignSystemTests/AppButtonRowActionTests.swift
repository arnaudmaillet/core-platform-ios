import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The row action (#2231): Follow, Accept and Approve on every row, named
/// once (`AppButton.Aspect.rowAction`), on the tinted ground (the owner's
/// decision, 2026-11-10) — in each state.
@MainActor
struct AppButtonRowActionTests {
    private func rowAction(_ title: String = "Follow") -> AppButton {
        let button = AppButton(aspect: .rowAction, size: .row, content: .title(title))
        button.reducesMotion = { false }
        return button
    }

    private func hosted(_ button: AppButton) -> (UIWindow, UIView) {
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

    private func resolved(_ color: UIColor?, _ style: UIUserInterfaceStyle = .light) -> UIColor? {
        color?.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    /// A row action is tinted; a pill keeps its own ground.
    @Test func aRowActionIsTinted() {
        let button = AppButton(aspect: .rowAction, size: .row, content: .title("Follow"))
        #expect(button.currentGround == .tinted)
        let pill = AppButton(aspect: .pill(.prominent), size: .row, content: .title("Follow"))
        #expect(pill.currentGround == .prominent)
    }

    // MARK: - Tinted

    /// The wash and its words while it invites; the quiet ground once acted
    /// (Following), as the prominent row buttons did.
    @Test func tintedIsTheWashThenTheQuietGround() {
        let button = rowAction()
        #expect(button.currentGround == .tinted)
        #expect(!button.usesProminentFill, "a row action is never the solid capsule")
        #expect(button.configuration?.baseBackgroundColor == Palette.primaryContainer)
        #expect(button.configuration?.baseForegroundColor == Palette.onPrimaryContainer)
        button.setContent(.title("Following"), selected: true, animated: false)
        #expect(button.currentGround == .quiet)
        #expect(button.configuration?.baseBackgroundColor == HeroTray.fill)
        #expect(button.configuration?.baseForegroundColor == .label)
        button.setContent(.title("Follow"), selected: false, animated: false)
        #expect(button.currentGround == .tinted)
    }

    @Test func aCallersSelectedGroundStillWins() {
        let button = rowAction()
        button.selectedGround = .monochrome
        button.isSelected = true
        #expect(button.currentGround == .monochrome)
    }

    @Test func disabledTintedIsGreyedOnItsGround() {
        let button = rowAction()
        button.isEnabled = false
        #expect(button.currentGround == .tinted)
        #expect(button.configuration?.baseForegroundColor == .tertiaryLabel)
        #expect(button.configuration?.background.backgroundColor == .tertiarySystemFill)
        #expect(!button.acceptsTaps)
    }

    // MARK: - Loading and placeholder

    /// An undrawn load keeps the words, faded; the width is held, taps are
    /// refused.
    @Test func aLoadHoldsTheWidth() {
        let button = rowAction()
        let before = button.fittingSize(for: button.content)
        button.setPhase(.loading, animated: false)
        #expect(button.debugHeldSize?.width == before.width)
        #expect(!button.acceptsTaps)
        let alpha = resolved(button.configuration?.baseForegroundColor)?.cgColor.alpha ?? 1
        #expect(abs(alpha - AppButton.MorphMetrics.loadingInkAlpha) < 0.01)
        #expect(button.currentGround == .tinted, "the load changed the ground")
    }

    /// A drawn load: the words blurred under the sheen.
    @Test func aDrawnLoadIsTheBlurredWords() {
        let button = rowAction()
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setPhase(.loading, animated: true)
        #expect(button.debugVeilIsShown, "the load was not drawn")
        #expect(button.debugIsUnderStandIn)
        button.setPhase(.content, animated: false)
        #expect(!button.debugIsUnderStandIn)
    }

    /// The placeholder holds the widest answer; its bone is the button's
    /// capsule.
    @Test func thePlaceholderBoneIsTheCapsule() throws {
        let button = rowAction()
        button.reservedContents = [.title("Follow"), .title("Following"), .title("Requested")]
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        button.setPhase(.placeholder, animated: false)
        host.layoutIfNeeded()
        button.layoutIfNeeded()
        let bone = try #require(button.debugBoneFrame)
        #expect(bone == button.bounds)
        #expect(!button.acceptsTaps)
    }

    // MARK: - Hit and press

    /// A row action keeps the 44 pt hit region, however small it draws.
    @Test func aRowActionKeepsTheHitRegion() {
        let button = rowAction("Follow")
        button.frame = CGRect(origin: .zero, size: button.fittingSize(for: button.content))
        #expect(button.hitRegion.width >= AppControl.Metrics.minimumHitSide)
        #expect(button.hitRegion.height >= AppControl.Metrics.minimumHitSide)
        #expect(button.point(inside: CGPoint(x: button.bounds.midX, y: button.bounds.midY - 18), with: nil))
    }

    /// The same press as every ground: the swell, attached once, no dim.
    @Test func theSamePress() {
        let button = rowAction()
        #expect(button.pressFeedback != nil)
        #expect(button.pressFeedback?.style == .swell)
    }
}
