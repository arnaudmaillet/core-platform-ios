import DesignSystem
import Foundation
import Testing
import UIKit
@testable import EmoteKit

private actor OneHandle: TextCompletionProviding {
    func completions(for kind: TextEntity.Kind, prefix: String) async -> [TextCompletion] {
        [TextCompletion(kind: .mention, value: "kenji.dev", title: "Kenji Tanaka")]
    }
}

/// The floating strips leave the window with their keyboard (#785).
///
/// ⚠️ **THEY FLOAT IN THE WINDOW, NOT IN THE COMPOSER.** The `:query` strip
/// and the `@`/`#` strip are window subviews in front of everything, and they
/// left only when the field stopped editing. An owner released without its
/// field resigning (a closed composer, a recycled cell) took the keyboard
/// with it and left a strip floating over whatever came next.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteKeyboardStripLifetimeTests {
    /// The field the strips float over lives in a hidden window; the text
    /// view stays off-window, which lets suggestions run without it being
    /// first responder.
    private func makeWindow() -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        let field = UIView(frame: CGRect(x: 16, y: 700, width: 300, height: 44))
        window.addSubview(field)
        return (window, field)
    }

    private func makeKeyboard(for textView: UITextView, anchoredTo field: UIView) -> EmoteKeyboard {
        let keyboard = EmoteKeyboard(
            textView: textView, engine: EmoteEngine(diskCache: nil),
            recents: EmoteRecents(defaults: UserDefaults(suiteName: "lifetime-\(UUID().uuidString)")!)
        )
        keyboard.suggestionAnchor = field
        return keyboard
    }

    private func takeDown(_ window: UIWindow) {
        window.subviews.forEach { $0.removeFromSuperview() }
        window.isHidden = true
    }

    private func type(_ text: String, in textView: UITextView) {
        textView.text = text
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: textView)
    }

    @Test func theEmoteStripLeavesTheWindowWhenItsKeyboardIsReleased() throws {
        let (window, field) = makeWindow()
        defer { takeDown(window) }
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        weak var released: EmoteKeyboard?
        var wasFloating = false
        // Built and dropped inside a pool, so nothing autoreleased keeps the
        // keyboard alive past the block.
        let strip: EmoteSuggestionStrip = autoreleasepool {
            let keyboard = makeKeyboard(for: textView, anchoredTo: field)
            released = keyboard
            type("gg :lol", in: textView)
            wasFloating = keyboard.suggestionStrip.window === window
            return keyboard.suggestionStrip
        }
        try #require(wasFloating, "guard: the emote strip never floated in the window")
        try #require(released == nil, "guard: something still holds the keyboard, so it was never released")
        // The field never resigned: only the release can have taken it away.
        #expect(strip.superview == nil, "the emote strip outlived its keyboard")
        #expect(!window.subviews.contains(strip), "the emote strip is still floating in the window")
    }

    @Test func theCompletionStripLeavesTheWindowWhenItsKeyboardIsReleased() async throws {
        let (window, field) = makeWindow()
        defer { takeDown(window) }
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        weak var released: EmoteKeyboard?
        var keyboard: EmoteKeyboard? = makeKeyboard(for: textView, anchoredTo: field)
        keyboard?.textCompleter = OneHandle()
        keyboard?.completionDebounce = .zero
        released = keyboard
        let strip = try #require(keyboard?.textCompletionStrip)

        type("ride with @ke", in: textView)
        try #require(await settle { keyboard?.isShowingCompletions == true },
                     "guard: the completion strip never showed")
        try #require(strip.window === window, "guard: the completion strip does not float in the window")

        autoreleasepool { keyboard = nil }
        try #require(released == nil, "guard: something still holds the keyboard, so it was never released")
        #expect(strip.superview == nil, "the completion strip outlived its keyboard")
        #expect(!window.subviews.contains(strip), "the completion strip is still floating in the window")
    }
}
