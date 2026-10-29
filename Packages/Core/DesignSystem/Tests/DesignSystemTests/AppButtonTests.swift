import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The app's button with words (#931, #1666): the grounds, the sizes, the
/// states, the motions and their fallbacks, the hit region, VoiceOver. The
/// icon-only buttons are `AppIconButtonTests`'.
@MainActor
struct AppButtonTests {
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

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func follow(reduced: Bool = false) -> AppButton {
        let button = AppButton(aspect: .pill(.prominent), size: .row, content: .title("Follow"))
        button.reducesMotion = { reduced }
        return button
    }

    // MARK: - Aspects and sizes

    @Test(arguments: [AppButton.Ground.prominent, .quiet, .tinted, .material])
    func everyPillGroundDrawsAGround(_ ground: AppButton.Ground) {
        let button = AppButton(aspect: .pill(ground), size: .header, content: .title("Message"))
        #expect(button.currentGround == ground)
        #expect(button.debugMaterialIsShown == (ground == .material), "only the material pill wears a blur")
        #expect(button.configuration?.title == "Message")
    }

    /// Follow is the pink-to-white gradient with white words (#1178);
    /// Following, the quiet grey in the label's ink; a greyed button and a
    /// placeholder wear no gradient.
    @Test func followIsTheSolidPinkWithWhiteWordsAndFollowingTheQuietGrey() {
        let button = follow()
        #expect(button.usesProminentFill)
        #expect(button.configuration?.baseBackgroundColor == .clear, "the solid view is the ground")
        #expect(button.configuration?.baseForegroundColor == .white)
        button.setSelected(true, animated: false)
        #expect(!button.usesProminentFill)
        #expect(button.configuration?.baseBackgroundColor == HeroTray.fill)
        #expect(button.configuration?.baseForegroundColor == .label)
        button.setSelected(false, animated: false)
        button.isEnabled = false
        #expect(!button.usesProminentFill, "greyed")
        button.isEnabled = true
        button.setPhase(.loading, animated: false)
        #expect(button.usesProminentFill, "a busy Follow keeps its ground under the white spinner (#1180)")
        button.setPhase(.placeholder, animated: false)
        #expect(!button.usesProminentFill, "the bone is the whole picture")
    }

    @Test func theCardShapeIsARoundedRectangle() {
        let button = AppButton(aspect: .pill(.quiet), size: .header, shape: .card, content: .title("Edit"))
        #expect(button.configuration?.cornerStyle == .fixed)
        #expect(button.configuration?.background.cornerRadius == AppButton.Metrics.cardRadius)
    }

    @Test func titleSymbolAndCountCombine() {
        let both = AppButton(aspect: .pill(.quiet), size: .header, content: AppButton.Content(title: "Likes", count: 7))
        #expect(both.configuration?.title == "Likes 7")
        let symbol = AppButton(aspect: .pill(.quiet), size: .header, content: AppButton.Content(title: "Save", symbol: "bookmark"))
        #expect(symbol.configuration?.image != nil)
    }

    // MARK: - Hit region

    @Test(arguments: AppButton.Size.allCases)
    func everySizeTakesAFingerOver44Points(_ size: AppButton.Size) {
        let button = AppButton(aspect: .pill(.quiet), size: size, content: .title("Go"))
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        host.layoutIfNeeded()
        let region = button.hitRegion
        #expect(region.width >= 44 && region.height >= 44, "\(size): \(region)")
        #expect(button.point(inside: CGPoint(x: region.minX + 1, y: region.minY + 1), with: nil))
        #expect(!button.point(inside: CGPoint(x: region.minX - 1, y: region.midY), with: nil))
    }

    // MARK: - States

    @Test func selectedSwapsProminentAndQuietAndSaysSo() {
        let button = follow()
        button.isToggle = true
        button.isSelected = true
        #expect(button.currentGround == .quiet, "Follow → Following goes quiet")
        #expect(button.accessibilityTraits.contains(.selected))
        #expect(button.accessibilityTraits.contains(.toggleButton))
    }

    @Test func disabledIsGreyedInertAndSilent() {
        let button = follow()
        button.haptic = .tick
        var tapped = 0
        button.addAction(UIAction { _ in tapped += 1 }, for: .primaryActionTriggered)
        button.isEnabled = false
        #expect(button.configuration?.baseForegroundColor == .tertiaryLabel)
        #expect(button.configuration?.background.backgroundColor == .tertiarySystemFill)
        #expect(!button.acceptsTaps)
        button.sendActions(for: .primaryActionTriggered)
        #expect(tapped == 0)
        #expect(!button.events.contains(.haptic(.tick)), "a disabled button plays nothing")
        #expect(button.accessibilityTraits.contains(.notEnabled), "VoiceOver reads it as dimmed")
        // A touch inside is still the button's, so it never reaches the row.
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        host.layoutIfNeeded()
        let centre = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        #expect(button.hitTest(centre, with: nil) === button, "a disabled button lets the finger through to its row")
        #expect(host.hitTest(button.convert(centre, to: host), with: nil) === button)
    }

    @Test func loadingHoldsTheWidthIgnoresTapsAndStaysFocusable() {
        let button = follow()
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        var tapped = 0
        button.addAction(UIAction { _ in tapped += 1 }, for: .primaryActionTriggered)
        let width = button.bounds.width
        let height = button.bounds.height
        #expect(width > 0)

        button.busyLabel = "Following…"
        button.setPhase(.loading, animated: false)
        host.layoutIfNeeded()
        #expect(button.configuration?.showsActivityIndicator == false, "a load has no spinner (the owner, 2026-10-23)")
        #expect(button.configuration?.title == "Follow", "an undrawn load keeps its words, faded")
        #expect(abs(button.bounds.width - width) < 0.5, "the width moved while loading: \(width) → \(button.bounds.width)")
        #expect(abs(button.bounds.height - height) < 0.5, "the load grew the pill: \(height) → \(button.bounds.height)")
        button.sendActions(for: .primaryActionTriggered)
        #expect(tapped == 0, "a re-tap reached the action while loading")
        #expect(button.isAccessibilityElement)
        #expect(button.accessibilityValue == "Following…")
        #expect(!button.accessibilityTraits.contains(.notEnabled), "busy is not disabled (Primer)")

        button.setPhase(.content, animated: false)
        button.sendActions(for: .primaryActionTriggered)
        #expect(tapped == 1)
        #expect(button.debugHeldSize == nil)
    }

    /// A load started before the first layout holds the content's real
    /// size, not the unresolved one (it came out "S…").
    @Test func aLoadStartedBeforeLayoutHoldsTheContentsSize() {
        let content = AppButton.Content(title: "Save", symbol: "bookmark")
        let button = AppButton(aspect: .pill(.quiet), size: .header, content: content)
        button.setPhase(.loading, animated: false)
        #expect(button.configuration?.showsActivityIndicator == false)
        #expect(button.configuration?.title == "Save")
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        host.layoutIfNeeded()
        #expect(abs(button.bounds.width - button.fittingSize(for: content).width) < 0.5, "held \(button.bounds)")
    }

    /// A drawn load holds the button as it stands the instant before its
    /// content changes — blurred under a sheen — takes the answer on the
    /// model unseen, and morphs to it when the load ends (the owner,
    /// 2026-10-23).
    @Test func aDrawnLoadHoldsTheBlurAndMorphsToTheAnswer() async {
        let button = follow()
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setPhase(.loading, animated: true)
        #expect(button.debugVeilIsShown, "the load was not drawn")
        #expect(button.debugIsUnderStandIn)
        button.setContent(.title("Following"), selected: true, animated: true)
        #expect(button.debugVeilIsShown, "the answer showed before the load ended")
        button.setPhase(.content, animated: true)
        #expect(button.events.last == .blurMorph)
        #expect(await settle { button.configuration?.title == "Following" && !button.debugVeilIsShown && !button.debugIsUnderStandIn })
        #expect(button.isSelected)
    }

    /// A drawn load that ends in a placeholder shows the bone, not a morph.
    @Test func aDrawnLoadIntoAPlaceholderShowsTheBone() {
        let button = follow()
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setPhase(.loading, animated: true)
        #expect(button.debugIsUnderStandIn)
        button.setPhase(.placeholder, animated: true)
        #expect(button.debugHasBone, "the load into a placeholder skipped the bone")
        #expect(!button.debugIsUnderStandIn)
        #expect(!button.debugVeilIsShown)
    }

    @Test func aPlaceholderHoldsTheWidestAnswerAndClaimsNone() {
        let button = follow()
        button.reservedContents = [.title("Follow"), .title("Following"), .title("Requested")]
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        button.setPhase(.placeholder, animated: false)
        host.layoutIfNeeded()
        let reserved = button.bounds.width
        let widest = button.fittingSize(for: .title("Following")).width
        #expect(abs(reserved - max(widest, button.fittingSize(for: .title("Requested")).width)) < 0.5)
        #expect(button.debugHasBone)
        #expect(button.configuration?.image == nil)
        #expect(!button.acceptsTaps, "a placeholder is inert")
        #expect(button.accessibilityValue == nil)
        #expect(!button.isAccessibilityElement, "a placeholder is spoken")

        button.setContent(.title("Following"), animated: false)
        button.setPhase(.content, animated: false)
        host.layoutIfNeeded()
        #expect(!button.debugHasBone)
        #expect(abs(button.bounds.width - widest) < 0.5, "the answer moved its neighbours: \(reserved) → \(button.bounds.width)")
    }

    /// A caller's label ("Follow Ava") survives every refresh; without one
    /// the title is the label.
    @Test func aCallersLabelSurvivesARefresh() {
        let button = follow()
        #expect(button.accessibilityLabel == "Follow")
        button.accessibilityLabel = "Follow Ava"
        button.setContent(.title("Following"), selected: true, animated: false)
        #expect(button.accessibilityLabel == "Follow Ava")
    }

    @Test func aGivenReservedWidthWins() {
        let button = follow()
        button.reservedWidth = 120
        button.setPhase(.placeholder, animated: false)
        #expect(button.intrinsicContentSize.width == 120)
    }

    /// A reserved slot holds the largest content whatever is shown, and the
    /// ground hugs the content shown, set in the slot by the anchor.
    @Test(arguments: AppButton.MorphAnchor.allCases)
    func aReservedSlotHoldsItsSizeAndSetsTheGroundByTheAnchor(_ anchor: AppButton.MorphAnchor) {
        let button = follow()
        button.reservedContents = [.title("Follow"), .title("Follow Back")]
        button.morphAnchor = anchor
        button.holdsReservedSize = true
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        let slot = button.bounds
        let ground = button.groundRect
        let natural = button.fittingSize(for: .title("Follow"))
        #expect(abs(slot.width - button.fittingSize(for: .title("Follow Back")).width) < 0.5)
        #expect(abs(ground.width - natural.width) < 0.5, "the ground hugs \"Follow\": \(ground.width) vs \(natural.width)")
        switch anchor {
        case .leading: #expect(abs(ground.minX - slot.minX) < 0.5)
        case .trailing: #expect(abs(ground.maxX - slot.maxX) < 0.5)
        case .center, .top, .bottom: #expect(abs(ground.midX - slot.midX) < 0.5)
        }

        button.setContent(.title("Follow Back"), animated: false)
        host.layoutIfNeeded()
        #expect(button.bounds.size == slot.size, "the slot moved its neighbours")
        #expect(abs(button.groundRect.width - slot.width) < 0.5, "the widest fills the slot")
    }

    // MARK: - Motion, and each fallback

    @Test(arguments: [false, true])
    func appearBouncesOrFades(_ reduced: Bool) {
        let button = follow(reduced: reduced)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.isHidden = true
        button.appear(animated: true)
        #expect(button.events.last == (reduced ? .fadeIn : .bounceIn))
        #expect(!button.isHidden)
    }

    @Test(arguments: [false, true])
    func disappearScalesOutOrFadesAndHides(_ reduced: Bool) async {
        let button = follow(reduced: reduced)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        var done = false
        button.disappear(animated: true) { done = true }
        #expect(button.events.last == (reduced ? .fadeOut : .scaleOut))
        #expect(button.isHidden, "a stack closes the gap in the same beat")
        #expect(await settle { done })
        #expect(button.transform == .identity, "it leaves no scale behind for the next appear")
    }

    @Test(arguments: [false, true])
    func aContentChangeBlursOrCrossFades(_ reduced: Bool) async {
        let button = follow(reduced: reduced)
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        let narrow = button.bounds.width
        button.setContent(.title("Follow Back"), animated: true)
        #expect(button.events.last == (reduced ? .crossFade : .blurMorph))
        if !reduced {
            // The new words are on the model at once, but never on screen
            // before the blur covers them: the button is hidden under its
            // stand-in, which draws the old words blurring.
            #expect(button.debugVeilIsShown)
            #expect(button.debugIsUnderStandIn, "the new words showed before the blur covered them")
        }
        #expect(await settle { button.configuration?.title == "Follow Back" && !button.debugVeilIsShown })
        host.layoutIfNeeded()
        #expect(button.bounds.width > narrow, "the width did not follow the content")
    }

    /// A double tap turns the morph around on its way: the button still
    /// takes the second tap, and the second change starts from what is on
    /// screen, not from the end of the first.
    @Test func aChangeMidMorphTurnsItAround() async {
        let button = follow()
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setContent(.title("Follow Back"), animated: true)
        #expect(button.debugIsUnderStandIn)
        #expect(button.alpha == 1, "a button under 0.01 alpha takes no tap: the second tap fell through")
        let middle = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        #expect(button.hitTest(middle, with: nil) === button, "the second tap did not reach the button")
        button.setContent(.title("Follow"), animated: true)
        #expect(button.events.last == .blurMorph)
        #expect(button.debugVeilIsShown)
        #expect(await settle { button.configuration?.title == "Follow" && !button.debugVeilIsShown && !button.debugIsUnderStandIn })
    }

    @Test(arguments: [false, true])
    func aFailureShakesOrFlashes(_ reduced: Bool) {
        let button = follow(reduced: reduced)
        button.notifiesCompletion = true
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.fail()
        #expect(button.events.suffix(2) == [.notification(success: false), reduced ? .failureFlash : .shake])
    }

    @Test func aSuccessCanMorphTheSymbol() {
        let button = AppButton(aspect: .pill(.quiet), size: .header, content: AppButton.Content(title: "Saved", symbol: "bookmark"))
        button.notifiesCompletion = true
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.succeed(showing: "checkmark")
        #expect(button.content.symbol == "checkmark")
        #expect(button.events.contains(.notification(success: true)))
    }

    /// Follow → Following: the title and the quiet ground swap under the
    /// same blur — never the ground first and the words a beat later.
    @Test(arguments: [false, true])
    func contentAndSelectionSwapTogether(_ reduced: Bool) async {
        let button = follow(reduced: reduced)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setContent(.title("Following"), selected: true, animated: true)
        #expect(button.events.last == (reduced ? .crossFade : .blurMorph))
        if !reduced {
            // The ground changes on the model under the stand-in, which
            // draws the old one blurring.
            #expect(button.debugVeilIsShown)
            #expect(button.debugIsUnderStandIn, "the ground changed before the blur covered it")
        }
        #expect(await settle { button.isSelected && button.configuration?.title == "Following" && !button.debugVeilIsShown })
        #expect(button.currentGround == .quiet)
    }

    /// A reused row's new person lands whole: an immediate change ends a
    /// morph still running, which must not swap the old answer in later.
    @Test func anImmediateChangeEndsAMorphInFlight() async {
        let button = follow()
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setContent(.title("Following"), selected: true, animated: true)
        button.setContent(.title("Follow Back"), selected: false, animated: false)
        #expect(!button.debugVeilIsShown)
        #expect(button.configuration?.title == "Follow Back")
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!button.isSelected, "the cancelled morph swapped its selection in")
        #expect(button.configuration?.title == "Follow Back")
    }

    /// The state tint is a fade, so it is the same on every setting.
    @Test func selectingCrossFadesTheTint() {
        let button = follow(reduced: true)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setSelected(true, animated: true)
        #expect(button.events.last == .stateTint)
        #expect(button.isSelected)
    }

    @Test func thePlaceholderFadesIntoTheContent() {
        let button = follow()
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setPhase(.placeholder, animated: false)
        button.setPhase(.content, animated: true)
        #expect(button.events.last == .placeholderReveal)
    }

    // MARK: - Press, haptic, sound

    /// One press per button (#866): a held press scales once, springs back
    /// once — and Reduce Motion takes the scale away. A pill SWELLS, as a
    /// system glass button does (the owner, 2026-10-23); a bare button gives.
    @Test(arguments: [false, true])
    func oneHeldPressScalesOnceAndSpringsBackOnce(_ reduced: Bool) throws {
        let button = follow(reduced: reduced)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        let press = try #require(button.pressFeedback)
        #expect(press.style == .swell)
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchDragEnter)
        #expect(press.isPressed)
        #expect(press.scale == (reduced ? 1 : PressFeedback.swelledScale(for: button.bounds.size).y))
        #expect(reduced || press.scale > 1, "a pill gave under the finger instead of swelling")
        button.sendActions(for: .touchUpInside)
        let presses = press.debugEvents.filter { if case .pressed = $0 { true } else { false } }
        let releases = press.debugEvents.filter { if case .released = $0 { true } else { false } }
        #expect(presses.count == 1)
        #expect(releases.count == 1)
        #expect(press.debugEvents.last == .released(tap: false, sprang: !reduced), "silent unless a sound is asked")
        #expect(PressFeedback.attached(to: button) === press, "a second press was attached")
    }

    @Test func aSoundIsTheTapsTick() throws {
        let button = AppButton(aspect: .pill(.quiet), size: .header, content: .title("Message"), sound: .tap)
        let press = try #require(button.pressFeedback)
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchUpInside)
        guard case .released(let tap, _)? = press.debugEvents.last else {
            Issue.record("no release recorded")
            return
        }
        #expect(tap, "a tap with a sound asked for did not tick")
    }

    @Test(arguments: [Haptic.tick, .toggleOn, .commit])
    func theHapticPlaysOnATap(_ haptic: Haptic) {
        let button = follow()
        button.haptic = haptic
        button.debugTap()
        #expect(button.events.last == .haptic(haptic))
    }

    @Test func noHapticByDefault() {
        let button = follow()
        button.debugTap()
        #expect(button.events.isEmpty)
    }

    @Test func aHoldCanFreezeTheScrollerWithoutTakingTheTap() throws {
        let button = follow()
        #expect(button.debugHoldRecognizer == nil)
        button.holdFreezesScrolling = true
        let hold = try #require(button.debugHoldRecognizer)
        #expect(hold.minimumPressDuration == AppButton.Metrics.holdDuration)
        #expect(AppButton.Metrics.holdDuration == 0.25, "shorter than a context menu's own timing")
        #expect(!hold.cancelsTouchesInView, "the button must keep tracking the finger for its tap")
        button.holdFreezesScrolling = false
        #expect(button.debugHoldRecognizer == nil)
    }

    // MARK: - Cell accessory

    /// The accessory reserves the button's real width at once, so taps land
    /// on it rather than falling through to the cell.
    @Test func theCellAccessoryReservesTheRealWidth() throws {
        let button = AppButton(aspect: .pill(.tinted), size: .row, content: AppButton.Content(title: "25", symbol: "diamond.fill"))
        let accessory = button.cellAccessory()
        let host = try #require(button.superview as? AppButton.AccessoryHost)
        #expect(host.bounds.width > 30, "the slot came out empty: \(host.bounds)")
        #expect(host.intrinsicContentSize == host.bounds.size)
        #expect(host.point(inside: CGPoint(x: host.bounds.midX, y: host.bounds.midY), with: nil))
        _ = accessory
    }

    // MARK: - Never glass

    @Test(arguments: ["AppControl", "AppButton", "AppIconButton"])
    func theComponentsNeverUseGlass(_ name: String) throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .appendingPathComponent("Sources/DesignSystem/Components/\(name).swift")
        let source = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let glass = try Regex(#"\.(prominentGlass|clearGlass|prominentClearGlass|glass)\s*\(|UIGlassEffect|UIGlassContainerEffect"#)
        #expect(!source.contains(glass), "\(name) uses a glass API")
    }
}
