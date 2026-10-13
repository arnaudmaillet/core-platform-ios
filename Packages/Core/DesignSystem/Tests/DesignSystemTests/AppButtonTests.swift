import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The app's one button (#931): two aspects, four sizes, the states, the
/// motions and their Reduce Motion fallbacks, the hit region, VoiceOver.
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

    @Test func theCardShapeIsARoundedRectangle() {
        let button = AppButton(aspect: .pill(.quiet), size: .header, shape: .card, content: .title("Edit"))
        #expect(button.configuration?.cornerStyle == .fixed)
        #expect(button.configuration?.background.cornerRadius == AppButton.Metrics.cardRadius)
    }

    @Test func aBareButtonHasNoGroundUntilButtonShapesAsksForOne() {
        let button = AppButton(aspect: .bare, size: .inline, content: AppButton.Content(symbol: "heart", count: 12))
        button.buttonShapes = { false }
        #expect(button.currentGround == nil)
        #expect(button.configuration?.background.backgroundColor == nil || button.configuration?.background.backgroundColor == .clear)
        button.buttonShapes = { true }
        #expect(button.currentGround == .quiet, "Button Shapes on: the bare aspect gains a visible shape")
    }

    @Test func titleSymbolAndCountCombine() {
        let button = AppButton(aspect: .bare, size: .inline, content: AppButton.Content(symbol: "heart", count: 1_234))
        #expect(button.configuration?.image != nil)
        #expect(button.configuration?.title == "1.2K", "a count is drawn compact")
        let both = AppButton(aspect: .pill(.quiet), size: .header, content: AppButton.Content(title: "Likes", count: 7))
        #expect(both.configuration?.title == "Likes 7")
        let icon = AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("qrcode"))
        #expect(icon.configuration?.title == nil)
        #expect(icon.intrinsicContentSize == CGSize(width: 44, height: 44))
    }

    // MARK: - Hit region

    @Test(arguments: AppButton.Size.allCases)
    func everySizeTakesAFingerOver44Points(_ size: AppButton.Size) {
        let button = AppButton(aspect: .bare, size: size, content: AppButton.Content(symbol: "heart", count: 3))
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
        let liked = AppButton(aspect: .bare, size: .inline, content: .symbol("heart"))
        liked.selectedTint = .systemRed
        liked.isSelected = true
        // The symbol turns red; the count keeps the ink.
        #expect(liked.configuration?.imageColorTransformer?(.label) == .systemRed)
        #expect(liked.configuration?.baseForegroundColor == .label)
        let ground = liked.configuration?.updated(for: liked).background.resolvedBackgroundColor(for: .systemBlue)
        #expect(ground == .clear, "a selected bare button grew a ground: \(String(describing: ground))")
    }

    @Test func disabledIsGreyedInertAndSilent() {
        let button = follow()
        button.haptic = .selection
        var tapped = 0
        button.addAction(UIAction { _ in tapped += 1 }, for: .primaryActionTriggered)
        button.isEnabled = false
        #expect(button.configuration?.baseForegroundColor == .tertiaryLabel)
        #expect(button.configuration?.background.backgroundColor == .tertiarySystemFill)
        #expect(!button.acceptsTaps)
        button.sendActions(for: .primaryActionTriggered)
        #expect(tapped == 0)
        #expect(!button.events.contains(.haptic(.selection)), "a disabled button plays nothing")
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
        #expect(button.configuration?.showsActivityIndicator == true)
        #expect(button.configuration?.title == nil, "the spinner replaces words-only content")
        #expect(abs(button.bounds.width - width) < 0.5, "the width moved while loading: \(width) → \(button.bounds.width)")
        #expect(abs(button.bounds.height - height) < 0.5, "the spinner grew the pill: \(height) → \(button.bounds.height)")
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
    @Test func aSymbolButtonKeepsItsWordsWhileTheSpinnerReplacesTheImage() {
        let content = AppButton.Content(title: "Save", symbol: "bookmark")
        let button = AppButton(aspect: .pill(.quiet), size: .header, content: content)
        button.setPhase(.loading, animated: false)
        #expect(button.configuration?.showsActivityIndicator == true)
        #expect(button.configuration?.title == "Save")
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        host.layoutIfNeeded()
        #expect(abs(button.bounds.width - button.fittingSize(for: content).width) < 0.5, "held \(button.bounds)")
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
            #expect(button.debugVeilIsShown)
            #expect(button.configuration?.title == "Follow", "the words changed before the blur covered them")
        }
        #expect(await settle { button.configuration?.title == "Follow Back" && !button.debugVeilIsShown })
        host.layoutIfNeeded()
        #expect(button.bounds.width > narrow, "the width did not follow the content")
    }

    @Test(arguments: [false, true])
    func aCountRollsOrFades(_ reduced: Bool) {
        let button = AppButton(aspect: .bare, size: .inline, content: AppButton.Content(symbol: "heart", count: 9))
        button.reducesMotion = { reduced }
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setContent(AppButton.Content(symbol: "heart", count: 10), animated: true)
        #expect(button.events.last == (reduced ? .countFade : .countRoll(up: true)))
        button.setContent(AppButton.Content(symbol: "heart", count: 8), animated: true)
        #expect(button.events.last == (reduced ? .countFade : .countRoll(up: false)))
        #expect(button.configuration?.title == "8")
        #expect(button.accessibilityValue == "8", "the count is the accessibility value")
    }

    @Test(arguments: [false, true])
    func aSymbolSwapIsReplacedOrFaded(_ reduced: Bool) {
        let button = AppButton(aspect: .bare, size: .inline, content: .symbol("bookmark"))
        button.reducesMotion = { reduced }
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setContent(.symbol("bookmark.fill"), animated: true)
        #expect(button.events.last == (reduced ? .symbolFade : .symbolReplace))
    }

    @Test(arguments: [false, true])
    func theSymbolEffectBouncesOrFlashes(_ reduced: Bool) {
        let button = AppButton(aspect: .bare, size: .inline, content: .symbol("heart"))
        button.reducesMotion = { reduced }
        button.bouncesSymbolOnTap = true
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.updateConfiguration()
        button.layoutIfNeeded()
        button.debugTap()
        #expect(button.events.last == (reduced ? .symbolFlash : .symbolBounce))
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
            #expect(!button.isSelected, "the ground changed before the blur covered it")
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
    /// once — and Reduce Motion takes the scale away.
    @Test(arguments: [false, true])
    func oneHeldPressScalesOnceAndSpringsBackOnce(_ reduced: Bool) throws {
        let button = follow(reduced: reduced)
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        let press = try #require(button.pressFeedback)
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchDragEnter)
        #expect(press.isPressed)
        #expect(press.scale == (reduced ? 1 : PressFeedback.pressedScale(for: button.bounds.size)))
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

    @Test(arguments: [AppButton.Haptic.selection, .lightImpact, .mediumImpact])
    func theHapticPlaysOnATap(_ haptic: AppButton.Haptic) {
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

    // MARK: - The card actions' press (#934)

    /// A card action: no dim, a wash inside its shape — one step pressed, a
    /// second held — gone once the finger lifts; a lift inside still taps.
    @Test func aCardActionWashesInsteadOfDimming() {
        let button = AppButton(aspect: .bare, size: .inline, content: .init(symbol: "heart", count: 3), dims: false)
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
        #expect(AppButton.Metrics.pressedWash < AppButton.Metrics.heldWash)
    }

    /// The hold shares the finger with the button's own recognisers (its
    /// menu's) and with nothing above it.
    @Test func theHoldSharesOnlyWithTheButtonsOwnRecognisers() throws {
        let host = UIScrollView()
        let button = AppButton(aspect: .bare, size: .inline, content: .symbol("heart"))
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
        let button = AppButton(aspect: .bare, size: .inline, content: .symbol("heart"))
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

    /// A card's glyph is drawn at its own size, not the type's.
    @Test func aSymbolPointSizeOverridesTheTypes() throws {
        let button = AppButton(aspect: .bare, size: .inline, content: .symbol("heart"))
        button.symbolPointSize = 17
        let symbol = try #require(button.configuration?.preferredSymbolConfigurationForImage)
        #expect(symbol == UIImage.SymbolConfiguration(pointSize: 17, weight: .medium, scale: .medium))
    }

    @Test func aMenuIsUIKits() {
        let button = AppButton(aspect: .pill(.quiet), size: .icon, content: .symbol("ellipsis"))
        button.menu = UIMenu(children: [UIAction(title: "Report") { _ in }])
        button.showsMenuAsPrimaryAction = true
        #expect(button.showsMenuAsPrimaryAction)
        #expect(button.showsLargeContentViewer, "an icon-only button shows large on a long press")
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

    @Test func theComponentNeverUsesGlass() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .appendingPathComponent("Sources/DesignSystem/Components/AppButton.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let glass = try Regex(#"\.(prominentGlass|clearGlass|prominentClearGlass|glass)\s*\(|UIGlassEffect|UIGlassContainerEffect"#)
        #expect(!source.contains(glass), "AppButton uses a glass API")
    }
}
