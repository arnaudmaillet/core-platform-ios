import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The row action (#2231): Follow, Accept and Approve on every row, named
/// once (`AppButton.Aspect.rowAction`). The tinted ground by default; bare
/// words behind `-row-action-style text` for the owner's comparison — each
/// look in each state, measured the same so a row never moves between them.
@MainActor
struct AppButtonRowActionTests {
    private func rowAction(_ style: AppButton.RowActionStyle, _ title: String = "Follow") -> AppButton {
        let button = AppButton(aspect: .rowAction, size: .row, content: .title(title))
        button.rowActionStyle = style
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

    /// The ground the configuration paints now, resolved: clear when none.
    private func paintedGround(_ button: AppButton) -> UIColor? {
        // The configuration as UIKit updates it for the button's state —
        // where `.plain()` grows its selected ground.
        button.updateConfiguration()
        return button.configuration?.updated(for: button).background.resolvedBackgroundColor(for: button.tintColor)
    }

    // MARK: - The flag

    /// Without the flag, tinted; `-row-action-style text` (or the
    /// dashboard's switch) draws words; a value after the argument wins.
    @Test func theFlagOffDrawsTintedAndTextDrawsWords() {
        let resolve = AppButton.RowActionStyle.resolve
        #expect(resolve([], false) == .tinted)
        #expect(resolve(["app"], false) == .tinted)
        #expect(resolve(["app", "-row-action-style", "text"], false) == .text)
        #expect(resolve(["app", "-row-action-style", "tinted"], false) == .tinted)
        #expect(resolve([], true) == .text, "the dashboard's switch")
        #expect(resolve(["app", "-row-action-style", "tinted"], true) == .tinted, "the argument wins over the switch")
        #expect(resolve(["app", "-row-action-style", "words"], false) == .tinted, "an unknown value is not a look")
        #expect(AppButton.RowActionStyle.argument == "-row-action-style")
        #expect(DebugFlags.all.contains { $0.argument == AppButton.RowActionStyle.argument })
    }

    /// A row action made without the flag — the test host's launch — is
    /// tinted; every other button ignores the style.
    @Test func aRowActionMadeWithoutTheFlagIsTinted() {
        let button = AppButton(aspect: .rowAction, size: .row, content: .title("Follow"))
        #expect(button.rowActionStyle == .tinted)
        #expect(button.currentGround == .tinted)
        #expect(!button.isBareRowAction)
        let pill = AppButton(aspect: .pill(.prominent), size: .row, content: .title("Follow"))
        pill.rowActionStyle = .text
        #expect(!pill.isBareRowAction, "a pill is never bare words")
        #expect(pill.currentGround == .prominent)
    }

    // MARK: - Tinted

    /// The wash and its words while it invites; the quiet ground once acted
    /// (Following), as the prominent row buttons did.
    @Test func tintedIsTheWashThenTheQuietGround() {
        let button = rowAction(.tinted)
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
        let button = rowAction(.tinted)
        button.selectedGround = .monochrome
        button.isSelected = true
        #expect(button.currentGround == .monochrome)
    }

    // MARK: - Text

    /// Bare words: no ground in any state — the tint inviting, the
    /// secondary ink once acted, the tertiary when greyed.
    @Test func textIsBareWordsInEveryState() {
        let button = rowAction(.text)
        #expect(button.isBareRowAction)
        #expect(button.currentGround == nil)
        #expect(button.configuration?.baseForegroundColor == Palette.rowActionText)
        #expect((paintedGround(button)?.cgColor.alpha ?? 0) == 0, "bare words grew a ground")

        button.setContent(.title("Following"), selected: true, animated: false)
        #expect(button.currentGround == nil)
        #expect(button.configuration?.baseForegroundColor == .secondaryLabel)
        #expect((paintedGround(button)?.cgColor.alpha ?? 0) == 0, "Following came out on a pill (.plain()'s selected ground)")

        button.isEnabled = false
        #expect(button.currentGround == nil)
        #expect(button.configuration?.baseForegroundColor == .tertiaryLabel)
        #expect((paintedGround(button)?.cgColor.alpha ?? 0) == 0, "a greyed bare action grew a grey ground")
    }

    @Test func disabledTintedIsGreyedOnItsGround() {
        let button = rowAction(.tinted)
        button.isEnabled = false
        #expect(button.currentGround == .tinted)
        #expect(button.configuration?.baseForegroundColor == .tertiaryLabel)
        #expect(button.configuration?.background.backgroundColor == .tertiarySystemFill)
        #expect(!button.acceptsTaps)
    }

    /// The style can change on a live button (the catalogues): it redraws.
    @Test func switchingTheLookRedraws() {
        let button = rowAction(.tinted)
        button.rowActionStyle = .text
        #expect(button.currentGround == nil)
        #expect(button.configuration?.baseForegroundColor == Palette.rowActionText)
        button.rowActionStyle = .tinted
        #expect(button.configuration?.baseBackgroundColor == Palette.primaryContainer)
    }

    // MARK: - Loading and placeholder

    /// An undrawn load keeps the words, faded, in both looks; the width is
    /// held, taps are refused.
    @Test(arguments: AppButton.RowActionStyle.allCases)
    func aLoadHoldsTheWidthInEitherLook(_ style: AppButton.RowActionStyle) {
        let button = rowAction(style)
        let before = button.fittingSize(for: button.content)
        button.setPhase(.loading, animated: false)
        #expect(button.debugHeldSize?.width == before.width)
        #expect(!button.acceptsTaps)
        let alpha = resolved(button.configuration?.baseForegroundColor)?.cgColor.alpha ?? 1
        #expect(abs(alpha - AppButton.MorphMetrics.loadingInkAlpha) < 0.01)
        #expect((button.currentGround == nil) == (style == .text), "the load changed the ground")
    }

    /// A drawn load: the words blurred under the sheen, in both looks.
    @Test(arguments: AppButton.RowActionStyle.allCases)
    func aDrawnLoadIsTheBlurredWordsInEitherLook(_ style: AppButton.RowActionStyle) {
        let button = rowAction(style)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setPhase(.loading, animated: true)
        #expect(button.debugVeilIsShown, "the load was not drawn")
        #expect(button.debugIsUnderStandIn)
        button.setPhase(.content, animated: false)
        #expect(!button.debugIsUnderStandIn)
    }

    /// The placeholder holds the widest answer in both looks; its bone is
    /// the button's capsule when tinted, the words' own box when bare.
    @Test(arguments: AppButton.RowActionStyle.allCases)
    func thePlaceholderBoneStandsWhereTheLookDraws(_ style: AppButton.RowActionStyle) throws {
        let button = rowAction(style)
        button.reservedContents = [.title("Follow"), .title("Following"), .title("Requested")]
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        button.setPhase(.placeholder, animated: false)
        host.layoutIfNeeded()
        button.layoutIfNeeded()
        let bone = try #require(button.debugBoneFrame)
        let insets = AppButton.insets(for: .row)
        switch style {
        case .tinted:
            #expect(bone == button.bounds)
        case .text:
            #expect(abs(bone.width - (button.bounds.width - insets.leading - insets.trailing)) < 0.5, "bone \(bone) in \(button.bounds)")
            #expect(abs(bone.height - (button.bounds.height - insets.top - insets.bottom)) < 0.5)
        }
        #expect(!button.acceptsTaps)
    }

    // MARK: - Measured the same

    /// Every row title, inviting and acted, measures the same in both
    /// looks: the row's layout does not move between them.
    @Test(arguments: ["Follow", "Follow Back", "Following", "Requested", "Accept", "Approve"])
    func bothLooksMeasureTheSame(_ title: String) {
        for selected in [false, true] {
            let tinted = rowAction(.tinted, title)
            let text = rowAction(.text, title)
            tinted.isSelected = selected
            text.isSelected = selected
            let a = tinted.fittingSize(for: .title(title))
            let b = text.fittingSize(for: .title(title))
            #expect(abs(a.width - b.width) < 0.01, "\(title) \(selected): \(a) vs \(b)")
            #expect(abs(a.height - b.height) < 0.01, "\(title) \(selected): \(a) vs \(b)")
        }
    }

    /// Bare words keep the 44 pt hit region, however small they draw.
    @Test func bareWordsKeepTheHitRegion() {
        let button = rowAction(.text, "Follow")
        button.frame = CGRect(origin: .zero, size: button.fittingSize(for: button.content))
        #expect(button.hitRegion.width >= AppControl.Metrics.minimumHitSide)
        #expect(button.hitRegion.height >= AppControl.Metrics.minimumHitSide)
        #expect(button.point(inside: CGPoint(x: button.bounds.midX, y: button.bounds.midY - 18), with: nil))
    }

    /// The same press as every ground: the swell, attached once, no dim.
    @Test(arguments: AppButton.RowActionStyle.allCases)
    func theSamePressInEitherLook(_ style: AppButton.RowActionStyle) {
        let button = rowAction(style)
        #expect(button.pressFeedback != nil)
        #expect(button.pressFeedback?.style == .swell)
    }
}
