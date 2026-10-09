import Foundation
import Testing
import UIKit
@testable import EmoteKit

/// The `:query` strip (#720): a Liquid Glass capsule as wide as its matches,
/// whose tiles come and go in the same spring that resizes it.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteSuggestionStripTests {
    /// The field the strip floats over lives in a (hidden) window; the text
    /// view itself stays off-window, which lets suggestions run without it
    /// being first responder.
    private func make() -> (UITextView, EmoteKeyboard, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        let field = UIView(frame: CGRect(x: 16, y: 700, width: 300, height: 44))
        window.addSubview(field)
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        let keyboard = EmoteKeyboard(
            textView: textView, engine: EmoteEngine(diskCache: nil),
            recents: EmoteRecents(defaults: UserDefaults(suiteName: "strip-\(UUID().uuidString)")!)
        )
        keyboard.suggestionAnchor = field
        return (textView, keyboard, window)
    }

    private func type(_ text: String, in textView: UITextView) {
        textView.text = text
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: textView)
    }

    private static func layers(under view: UIView) -> [CALayer] {
        [view.layer] + view.subviews.flatMap { layers(under: $0) }
    }

    @Test func theStripIsGlassAndAsWideAsItsMatches() throws {
        let (textView, keyboard, window) = make()
        defer { window.isHidden = true }
        let strip = keyboard.suggestionStrip
        #expect(strip.isGlass, "the strip is not Liquid Glass")
        #expect(strip.isInteractiveGlass, "the strip's glass has no native press response (#730)")

        type("gg :lol", in: textView)
        let few = keyboard.suggestionIDs.count
        try #require(few > 0)
        #expect(strip.window === window, "the strip does not float in the field's window")
        strip.layer.removeAllAnimations()
        #expect(abs(strip.bounds.width - EmoteSuggestionStrip.fittingWidth(count: few)) < 0.5,
                "\(strip.bounds.width) for \(few) matches")
        #expect(strip.frame.minX == 16, "the strip does not start at the field's leading edge")
        #expect(strip.frame.maxY <= 700, "the strip covers the field")

        type("gg :fi", in: textView)
        let many = keyboard.suggestionIDs.count
        try #require(many > few)
        strip.layer.removeAllAnimations()
        let expected = min(EmoteSuggestionStrip.fittingWidth(count: many), 390 - 16, 520)
        #expect(abs(strip.frame.width - expected) < 0.5, "\(strip.frame.width) for \(many) matches")
        #expect(strip.frame.maxX <= 390 - 8 + 0.5, "a wide strip runs off the screen")

        // One match is a round capsule's worth, not a full-width bar.
        #expect(EmoteSuggestionStrip.fittingWidth(count: 1) < 60)
        #expect(EmoteSuggestionStrip.fittingWidth(count: 0) == 0)
    }

    /// The emote keyboard's section bar answers a touch natively (#730).
    @Test func theKeyboardsSectionBarIsInteractiveGlass() {
        let (_, keyboard, window) = make()
        defer { window.isHidden = true }
        let panel = keyboard.panel
        window.addSubview(panel)
        let effect = panel.sectionBarGlass.effect as? UIGlassEffect
        #expect(effect != nil, "the section bar is not glass")
        #expect(effect?.isInteractive == true, "the section bar's glass has no native press response")
    }

    /// Narrowing the query removes tiles and shrinks the capsule in ONE
    /// spring: the capsule's frame and the tiles' moves share a timing.
    @Test func aNarrowerQueryShrinksTilesAndCapsuleInOneSpring() throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let (textView, keyboard, window) = make()
        defer { window.isHidden = true }
        let strip = keyboard.suggestionStrip
        type("gg :lo", in: textView)
        let before = keyboard.suggestionIDs
        try #require(before.count > 1)
        strip.layoutIfNeeded()
        strip.layer.removeAllAnimations()
        Self.layers(under: strip).forEach { $0.removeAllAnimations() }

        type("gg :lol", in: textView)
        let after = keyboard.suggestionIDs
        try #require(after.count < before.count && !after.isEmpty)

        let update = try #require(strip.lastUpdate, "the narrower query reloaded rather than animating")
        #expect(update.removed.count == before.count - after.count + update.inserted.count)
        #expect(!update.removed.isEmpty)

        let capsule = try #require(
            strip.layer.animationKeys()?.compactMap { strip.layer.animation(forKey: $0) }
                .first { ($0 as? CABasicAnimation)?.keyPath?.hasPrefix("bounds") == true },
            "the capsule's width did not animate"
        )
        #expect(abs(capsule.duration - EmoteKeyboard.suggestionSpring) < 0.01)

        let tileAnimations = Self.layers(under: strip).filter { $0 !== strip.layer }
            .flatMap { layer in (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) } }
        #expect(!tileAnimations.isEmpty, "the tiles did not animate")
        for animation in tileAnimations {
            #expect(abs(animation.duration - capsule.duration) < 0.01,
                    "a tile moved on its own timing (\(animation.duration)s vs \(capsule.duration)s)")
        }
    }

    /// The query gone: the strip leaves; a new query brings it back at once.
    @Test func theStripLeavesAndComesBack() async throws {
        let (textView, keyboard, window) = make()
        defer { window.isHidden = true }
        let strip = keyboard.suggestionStrip
        type("gg :lol", in: textView)
        #expect(strip.superview != nil)
        type("gg ", in: textView)
        #expect(keyboard.suggestionIDs.isEmpty || strip.alpha == 0 || strip.superview == nil)
        type("gg :lol", in: textView)
        #expect(strip.superview != nil)
        #expect(!keyboard.suggestionIDs.isEmpty)
        try #require(await settle { strip.layer.animationKeys()?.isEmpty ?? true })
        #expect(strip.superview != nil, "an old hide took away the strip shown again")
        #expect(strip.alpha == 1)
    }
}
