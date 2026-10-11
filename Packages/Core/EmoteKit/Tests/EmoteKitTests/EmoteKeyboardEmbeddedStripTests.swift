import Foundation
import Testing
import UIKit
@testable import EmoteKit

/// The strips riding a composer (#960): laid out in the composer from the
/// field's edges, so they move and widen in the pass that moves the field.
///
/// ⚠️ **FLOATING, THE STRIP WAS PLACED ONCE PER QUERY.** A field the
/// keyboard then lifted left it behind, and a field widening on focus
/// widened under a strip that kept its width.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteKeyboardEmbeddedStripTests {
    /// A composer in a hidden window: a container holding the field, which
    /// the keyboard (`bottom`) lifts and the side items (`trailing`) widen.
    /// The text view stays off-window, which lets suggestions run without it
    /// being first responder.
    private struct Composer {
        let window: UIWindow
        let container: UIView
        let field: UIView
        let bottom: NSLayoutConstraint
        let trailing: NSLayoutConstraint
        let textView: UITextView
        let keyboard: EmoteKeyboard
    }

    /// The field's resting width: a few tiles' worth, so a long query's
    /// strip is capped by the field's trailing edge.
    private static let restTrailingInset: CGFloat = 200

    private func makeComposer() -> Composer {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        let field = UIView()
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        let bottom = field.bottomAnchor.constraint(equalTo: container.topAnchor, constant: 744)
        let trailing = field.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -Self.restTrailingInset
        )
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            trailing, bottom,
            field.heightAnchor.constraint(equalToConstant: 44),
        ])
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        let keyboard = EmoteKeyboard(
            textView: textView, engine: EmoteEngine(diskCache: nil),
            recents: EmoteRecents(defaults: UserDefaults(suiteName: "embedded-\(UUID().uuidString)")!)
        )
        keyboard.embedSuggestions(
            in: container, leading: field.leadingAnchor, trailing: field.trailingAnchor, bottom: field.topAnchor
        )
        container.layoutIfNeeded()
        return Composer(window: window, container: container, field: field, bottom: bottom,
                        trailing: trailing, textView: textView, keyboard: keyboard)
    }

    private func type(_ text: String, in textView: UITextView) {
        textView.text = text
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: textView)
    }

    private static func layers(under view: UIView) -> [CALayer] {
        [view.layer] + view.subviews.flatMap { layers(under: $0) }
    }

    /// The strip on the field: `stripGap` above it, from its leading edge,
    /// as wide as its matches but never past the field's trailing edge.
    private func expectOnField(
        _ strip: UIView, _ field: UIView, matches: Int, _ stage: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let width = min(EmoteSuggestionStrip.fittingWidth(count: matches), field.frame.width,
                        EmoteKeyboard.stripMaxWidth)
        #expect(abs(strip.frame.maxY - (field.frame.minY - EmoteKeyboard.stripGap)) < 0.5,
                "\(stage): strip bottom \(strip.frame.maxY), field top \(field.frame.minY)",
                sourceLocation: sourceLocation)
        #expect(abs(strip.frame.minX - field.frame.minX) < 0.5,
                "\(stage): strip leading \(strip.frame.minX), field leading \(field.frame.minX)",
                sourceLocation: sourceLocation)
        #expect(abs(strip.frame.width - width) < 0.5,
                "\(stage): strip width \(strip.frame.width) for \(matches) matches over \(field.frame.width)",
                sourceLocation: sourceLocation)
        #expect(strip.frame.height == EmoteSuggestionStrip.height, sourceLocation: sourceLocation)
    }

    /// The `animation` on `layer` whose key path starts with `prefix`.
    private static func animation(_ prefix: String, on layer: CALayer) -> CAAnimation? {
        (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
            .first { ($0 as? CABasicAnimation)?.keyPath?.hasPrefix(prefix) == true }
    }

    /// ⚠️ THE STRIP TRACKS THE FIELD, KEYBOARD SHOW AND FOCUS WIDEN. The
    /// field rises (a keyboard's ceiling) and then widens (the side items
    /// giving way), each in an animation; the strip moves and widens in the
    /// SAME animation — its position and width animate with the field's
    /// timing — and lands on the field at every stage.
    @Test func theStripTracksTheFieldThroughAKeyboardShowAndAWiden() throws {
        let composer = makeComposer()
        defer { composer.window.isHidden = true }
        let strip = composer.keyboard.suggestionStrip
        let field = composer.field
        #expect(strip.superview == nil, "a composer nobody typed `:` in holds a strip")

        type("gg :fi", in: composer.textView)
        let matches = composer.keyboard.suggestionIDs.count
        try #require(matches > 0)
        #expect(strip.superview === composer.container, "the strip does not ride in the composer")
        #expect(!strip.isHidden)
        // Capped at rest, so the widen has room to show.
        try #require(EmoteSuggestionStrip.fittingWidth(count: matches) > field.frame.width + 40,
                     "\(matches) matches fit the resting field: nothing to widen")
        Self.layers(under: strip).forEach { $0.removeAllAnimations() }
        expectOnField(strip, field, matches: matches, "at rest")
        let rest = strip.frame

        // The keyboard comes up: the field rises in the keyboard's animation.
        UIView.animate(withDuration: 0.31, delay: 0, options: [.curveEaseOut]) {
            composer.bottom.constant = 400
            composer.container.layoutIfNeeded()
        }
        expectOnField(strip, field, matches: matches, "risen")
        #expect(strip.frame.minY < rest.minY - 300, "the strip stayed behind: \(strip.frame) vs \(rest)")
        let fieldRise = try #require(Self.animation("position", on: field.layer), "the field did not animate")
        let stripRise = try #require(
            Self.animation("position", on: strip.layer), "the strip did not move in the field's animation"
        )
        #expect(abs(stripRise.duration - fieldRise.duration) < 0.001,
                "the strip rose on its own timing (\(stripRise.duration)s vs \(fieldRise.duration)s)")
        #expect(abs(stripRise.duration - 0.31) < 0.001)
        Self.layers(under: composer.container).forEach { $0.removeAllAnimations() }

        // Focused, the side items give way: the field widens, and the strip
        // with it, in one animation.
        UIView.animate(withDuration: 0.27) {
            composer.trailing.constant = -16
            composer.container.layoutIfNeeded()
        }
        expectOnField(strip, field, matches: matches, "widened")
        #expect(strip.frame.width > rest.width + 40, "the strip did not widen: \(strip.frame.width) vs \(rest.width)")
        let fieldWiden = try #require(Self.animation("bounds", on: field.layer), "the field did not widen")
        let stripWiden = try #require(
            Self.animation("bounds", on: strip.layer), "the strip did not widen in the field's animation"
        )
        #expect(abs(stripWiden.duration - fieldWiden.duration) < 0.001)
        #expect(abs(stripWiden.duration - 0.27) < 0.001)
        Self.layers(under: composer.container).forEach { $0.removeAllAnimations() }

        // And back: the keyboard leaves, the field narrows and comes home.
        composer.bottom.constant = 744
        composer.trailing.constant = -Self.restTrailingInset
        composer.container.layoutIfNeeded()
        expectOnField(strip, field, matches: matches, "home")
        #expect(strip.frame == rest, "the strip did not come home with the field: \(strip.frame) vs \(rest)")
        #expect(!composer.container.hasAmbiguousLayout)
    }

    /// A short query's strip keeps its matches' width on a wide field.
    @Test func aShortQueryKeepsItsMatchesWidth() throws {
        let composer = makeComposer()
        defer { composer.window.isHidden = true }
        composer.trailing.constant = -16
        composer.container.layoutIfNeeded()
        let strip = composer.keyboard.suggestionStrip
        type("gg :lol", in: composer.textView)
        let matches = composer.keyboard.suggestionIDs.count
        try #require(matches > 0)
        try #require(EmoteSuggestionStrip.fittingWidth(count: matches) < composer.field.frame.width)
        Self.layers(under: strip).forEach { $0.removeAllAnimations() }
        expectOnField(strip, composer.field, matches: matches, "short query")
    }

    /// Gone, the strip stays in the composer, hidden and untouchable; a new
    /// query brings it back on the field, where the field now is.
    @Test func aHiddenStripStaysInTheComposer() async throws {
        let composer = makeComposer()
        defer { composer.window.isHidden = true }
        let strip = composer.keyboard.suggestionStrip
        type("gg :lol", in: composer.textView)
        try #require(!composer.keyboard.suggestionIDs.isEmpty)
        Self.layers(under: strip).forEach { $0.removeAllAnimations() }
        let inside = CGPoint(x: strip.frame.midX, y: strip.frame.midY)
        #expect(composer.keyboard.suggestionsContain(inside, in: composer.container),
                "a tile on the strip is not the composer's touch")
        #expect(!composer.keyboard.suggestionsContain(CGPoint(x: inside.x, y: strip.frame.maxY + 4),
                                                      in: composer.container))

        type("gg ", in: composer.textView)
        try #require(await settle { strip.isHidden })
        #expect(strip.superview === composer.container, "the hidden strip was taken out of the composer")
        #expect(!composer.keyboard.suggestionsContain(inside, in: composer.container),
                "a hidden strip still takes touches")

        // The keyboard rose while it was away.
        composer.bottom.constant = 400
        composer.container.layoutIfNeeded()
        type("gg :lol", in: composer.textView)
        #expect(!strip.isHidden)
        Self.layers(under: strip).forEach { $0.removeAllAnimations() }
        expectOnField(strip, composer.field, matches: composer.keyboard.suggestionIDs.count, "back")
        try #require(await settle { strip.layer.animationKeys()?.isEmpty ?? true })
        #expect(strip.alpha == 1)
    }
}
