import DesignSystem
import Foundation
import Testing
import UIKit
@testable import EmoteKit

/// `@` and `#` completions in a composer (#524).
private actor FakeCompletions: TextCompletionProviding {
    private(set) var asked: [(TextEntity.Kind, String)] = []
    func completions(for kind: TextEntity.Kind, prefix: String) async -> [TextCompletion] {
        asked.append((kind, prefix))
        switch kind {
        case .mention: return [TextCompletion(kind: .mention, value: "kenji.dev", title: "Kenji Tanaka")]
        case .hashtag: return [TextCompletion(kind: .hashtag, value: "travel")]
        }
    }
    var lastPrefix: String? { asked.last?.1 }
}

@MainActor
@Suite(.serialized, .sharesMainThread)
struct TextCompletionKeyboardTests {
    private func make() -> (UITextView, EmoteKeyboard, FakeCompletions) {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        let keyboard = EmoteKeyboard(
            textView: textView, engine: EmoteEngine(diskCache: nil),
            recents: EmoteRecents(defaults: UserDefaults(suiteName: "completions-\(UUID().uuidString)")!)
        )
        let completions = FakeCompletions()
        keyboard.textCompleter = completions
        keyboard.completionDebounce = .zero
        return (textView, keyboard, completions)
    }

    private func type(_ text: String, in textView: UITextView) {
        textView.text = text
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: textView)
    }

    private func settle(_ keyboard: EmoteKeyboard, until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aHandleBeingTypedIsCompletedWithItsSpace() async {
        let (textView, keyboard, completions) = make()
        type("ride with @ke", in: textView)
        await settle(keyboard) { !keyboard.completionTokens.isEmpty }

        #expect(keyboard.completionTokens == ["@kenji.dev"])
        #expect(await completions.lastPrefix == "ke")
        keyboard.selectCompletion(at: 0)
        #expect(textView.text == "ride with @kenji.dev ")
        #expect(textView.selectedRange.location == ("ride with @kenji.dev " as NSString).length)
        #expect(keyboard.completionTokens.isEmpty)
    }

    @Test func aTagBeingTypedIsCompleted() async {
        let (textView, keyboard, _) = make()
        type("on the #tr", in: textView)
        await settle(keyboard) { !keyboard.completionTokens.isEmpty }

        #expect(keyboard.completionTokens == ["#travel"])
        keyboard.selectCompletion(at: 0)
        #expect(textView.text == "on the #travel ")
    }

    /// Off a token, or once it is finished, nothing is offered.
    @Test func noTokenNoCompletions() async {
        let (textView, keyboard, _) = make()
        type("ride with @ke", in: textView)
        await settle(keyboard) { !keyboard.completionTokens.isEmpty }
        type("ride with @ke ", in: textView)
        #expect(keyboard.completionTokens.isEmpty)
        type("mail a@b", in: textView)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(keyboard.completionTokens.isEmpty)
    }

    /// An emote query is its own: `:` wins over a handle typed before it.
    @Test func anEmoteQueryWins() async {
        let (textView, keyboard, _) = make()
        type("gg :lo", in: textView)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(keyboard.completionTokens.isEmpty)
        #expect(keyboard.suggestionIDs.first == "lol")
    }

    @Test func turnedOffItCompletesNothing() async {
        let (textView, keyboard, completions) = make()
        keyboard.completesTextEntities = false
        type("ride with @ke", in: textView)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(keyboard.completionTokens.isEmpty)
        #expect(await completions.asked.isEmpty)
    }
}
