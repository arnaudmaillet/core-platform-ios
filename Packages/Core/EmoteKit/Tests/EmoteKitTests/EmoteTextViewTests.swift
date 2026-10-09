import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The composer's field (#699): emotes are one attachment each, playing in
/// place, while the text it gives back — sent, drafted, copied — is byte for
/// byte what a plain text view would have held.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteTextViewTests {
    private let font = UIFont.systemFont(ofSize: 17)

    private func warmEngine(_ ids: [String]) throws -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil)
        for id in ids {
            let emote = try #require(engine.catalog.emote(id: id))
            for side in EmoteEngine.pixelBuckets {
                engine.insert(EmoteLabelTests.syntheticArt(side: side), for: emote, pixelSide: side, motion: .loop)
                engine.insert(EmoteLabelTests.syntheticArt(side: side, frames: 1), for: emote, pixelSide: side, motion: .still)
            }
        }
        return engine
    }

    private func hostedField(
        _ text: String, engine: EmoteEngine = EmoteEngine(diskCache: nil)
    ) -> (EmoteTextView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        window.isHidden = false
        let field = EmoteTextView(engine: engine)
        field.font = font
        field.frame = CGRect(x: 10, y: 10, width: 300, height: 400)
        window.addSubview(field)
        field.plainText = text
        field.layoutIfNeeded()
        return (field, window)
    }

    private func attachmentCount(_ field: EmoteTextView) -> Int {
        var count = 0
        field.textStorage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: field.textStorage.length)
        ) { value, range, _ in
            if value is EmoteAttachment { count += range.length }
        }
        return count
    }

    // MARK: - The text

    /// ⚠️ THE WIRE FORMAT DOES NOT CHANGE: emoji and `:code:`s — case kept —
    /// come back exactly as written, though each is one character in the
    /// field.
    @Test func thePlainTextComesBackByteForByte() {
        let text = "hot 🔥 take :lol: and :LOL: :nope: 👍🏽 end"
        let (field, _) = hostedField(text)
        #expect(field.plainText == text)
        #expect(field.textLayoutManager != nil, "the field fell back to TextKit 1")
        // 🔥, :lol:, :LOL: are emotes; an unknown code and a skin-toned thumb stay text.
        #expect(attachmentCount(field) == 3)
        #expect(field.textStorage.length < (text as NSString).length)
    }

    /// Ranges map between the plain text and the storage; a bound inside an
    /// emote's source takes the whole emote.
    @Test func rangesMapThroughTheEmotes() {
        let (field, _) = hostedField("a:lol:b")
        #expect(field.textStorage.length == 3)
        #expect(field.plainRange(forStorage: NSRange(location: 2, length: 1)) == NSRange(location: 6, length: 1))
        #expect(field.storageRange(forPlain: NSRange(location: 1, length: 5)) == NSRange(location: 1, length: 1))
        #expect(field.storageRange(forPlain: NSRange(location: 3, length: 0)) == NSRange(location: 1, length: 1))
        field.plainSelectedRange = NSRange(location: 6, length: 0)
        #expect(field.selectedRange == NSRange(location: 2, length: 0))
    }

    /// A code typed by hand becomes the emote as its colon closes, the
    /// caret staying after it; the text is unchanged.
    @Test func typingACodeTurnsItIntoTheEmote() {
        let (field, _) = hostedField("ha :lol")
        // What a keystroke does to the storage; the edit's end converts.
        func type(_ text: String) {
            let caret = field.selectedRange.location
            field.textStorage.replaceCharacters(
                in: NSRange(location: caret, length: 0),
                with: NSAttributedString(string: text, attributes: [.font: font])
            )
            field.selectedRange = NSRange(location: caret + (text as NSString).length, length: 0)
            NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: field)
        }
        field.plainSelectedRange = NSRange(location: 7, length: 0)
        type(":")
        #expect(field.plainText == "ha :lol:")
        #expect(attachmentCount(field) == 1)
        #expect(field.plainSelectedRange == NSRange(location: 8, length: 0))
        type(" 🔥")
        #expect(field.plainText == "ha :lol: 🔥")
        #expect(attachmentCount(field) == 2)
    }

    /// Undo walks back through the conversion first, then the typing.
    @Test func undoTurnsTheEmoteBackIntoText() throws {
        let (field, _) = hostedField("ha :lol:")
        let undo = try #require(field.undoManager)
        undo.removeAllActions()
        field.textStorage.replaceCharacters(in: NSRange(location: field.textStorage.length, length: 0), with: NSAttributedString(string: " :lol:", attributes: [.font: font]))
        undo.beginUndoGrouping()
        field.convertTypedEmotes()
        undo.endUndoGrouping()
        #expect(attachmentCount(field) == 2)
        undo.undo()
        #expect(field.plainText == "ha :lol: :lol:", "undo changed the text, not just its drawing")
        #expect(attachmentCount(field) == 1)
        undo.redo()
        #expect(attachmentCount(field) == 2)
    }

    /// Copy gives the plain text — never an image.
    @Test func copyGivesTheCodesAndEmoji() {
        let (field, _) = hostedField("x :lol: 🔥 y")
        field.selectedRange = NSRange(location: 0, length: field.textStorage.length)
        // A private pasteboard: reading the general one asks to paste.
        let pasteboard = UIPasteboard.withUniqueName()
        field.pasteboard = pasteboard
        field.copy(nil)
        #expect(pasteboard.string == "x :lol: 🔥 y")
    }

    /// VoiceOver hears a house emote's name, an emoji as itself.
    @Test func voiceOverReadsTheEmoteNotAnAttachment() {
        let (field, _) = hostedField("ok :lol: 🔥")
        #expect(field.accessibilityValue == "ok lol 🔥")
    }

    /// An emote is sized to the line: a line holding one is no taller than
    /// the same line of plain text, so the field's growth never jumps.
    @Test func anEmoteNeverMakesItsLineTaller() {
        let (field, window) = hostedField("hello :lol: there 🔥")
        let plain = UITextView(frame: field.frame)
        plain.font = font
        plain.text = "hello x there y"
        window.addSubview(plain)
        func usedHeight(_ view: UITextView) -> CGFloat {
            guard let layout = view.textLayoutManager else { return -1 }
            layout.ensureLayout(for: layout.documentRange)
            return layout.usageBoundsForTextContainer.height
        }
        #expect(abs(usedHeight(field) - usedHeight(plain)) < 0.5, "\(usedHeight(field)) vs \(usedHeight(plain))")
    }

    // MARK: - Playing

    /// Each emote gets a view that shows the art over its still once baked.
    @Test func eachEmotePlaysInPlace() async throws {
        let engine = try warmEngine(["noto:1f525", "lol"])
        let (field, window) = hostedField("hot 🔥 take :lol:", engine: engine)
        _ = window
        try #require(await settle { field.emoteViews.count == 2 })
        #expect(field.emoteViews.allSatisfy { $0.isShowingArt })
        #expect(field.emoteViews.allSatisfy { !$0.showsStill })
    }

    /// Before the art, the still glyph shows — never a blank.
    @Test func aColdEmoteShowsItsStill() async throws {
        let engine = EmoteEngine(diskCache: nil, animationProvider: { _ in nil })
        let (field, window) = hostedField("cold :lol:", engine: engine)
        _ = window
        try #require(await settle { field.emoteViews.count == 1 })
        #expect(field.emoteViews.allSatisfy { $0.showsStill })
        #expect(!field.emoteViews.contains { $0.isShowingArt })
    }

    /// ⚠️ THE APP-WIDE BUDGET HOLDS: past it, emotes keep their still.
    @Test func theBudgetCapsAnimations() async throws {
        // An emoji: a house icon's art is one sheet for both motions, so the
        // warm engine's still would stand in for its loop.
        let engine = try warmEngine(["noto:1f525"])
        engine.maxAnimatedEmotes = 3
        let (field, window) = hostedField(String(repeating: "🔥 ", count: 8), engine: engine)
        _ = window
        try #require(await settle { field.emoteViews.count == 8 })
        #expect(field.emoteViews.filter { $0.isShowingArt }.count == 3)
        #expect(field.emoteViews.filter { $0.showsStill }.count == 5)
    }

    /// Under Reduce Motion an emoji keeps its still glyph and a house emote
    /// shows its still art; nothing holds an animation slot.
    @Test func reduceMotionShowsStills() async throws {
        AnimatedIconView.forcedPolicy = .still
        defer { AnimatedIconView.forcedPolicy = nil }
        let engine = try warmEngine(["noto:1f525", "lol"])
        let (field, window) = hostedField("🔥 :lol:", engine: engine)
        _ = window
        try #require(await settle { field.emoteViews.count == 2 })
        let views = field.emoteViews
        #expect(views[0].showsStill && !views[0].isShowingArt, "the emoji left its glyph")
        #expect(views[1].isShowingArt, "the house emote shows no art")
        #expect(engine.animatedCount == 0, "a still must not hold an animation slot")
    }

    /// ⚠️ SCROLLING PLACES NOTHING: the views ride in the content, and a
    /// scroll view lays out on every frame of a scroll. Only an edit, or a
    /// new width, places them again.
    @Test func scrollingTheFieldPlacesNothing() throws {
        let (field, _) = hostedField(String(repeating: "line :lol: 🔥\n", count: 40))
        field.frame.size.height = 120
        field.layoutIfNeeded()
        let placed = field.placementPasses
        let before = field.emoteViews.map(\.frame)
        for offset in stride(from: 0, through: 600, by: 50) {
            field.contentOffset.y = CGFloat(offset)
            field.layoutIfNeeded()
        }
        #expect(field.placementPasses == placed, "a scroll re-placed the emotes")
        #expect(field.emoteViews.map(\.frame) == before)
        field.plainText += " :lol:"
        field.layoutIfNeeded()
        #expect(field.placementPasses > placed, "an edit did not place the new emote")
        #expect(field.emoteViews.count == 81)
    }

    // MARK: - The keyboard

    /// The panel writes through the plain text: a pick lands at the caret as
    /// the emote, and backspace takes it whole.
    @Test func thePanelPicksAndDeletesWholeEmotes() throws {
        let (field, _) = hostedField("hello world")
        let keyboard = EmoteKeyboard(
            textView: field, engine: field.engine,
            recents: EmoteRecents(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        field.plainSelectedRange = NSRange(location: 5, length: 0)
        let lol = try #require(field.engine.catalog.emote(code: "lol"))
        keyboard.pick(lol)
        #expect(field.plainText == "hello:lol: world")
        #expect(field.plainSelectedRange == NSRange(location: 10, length: 0))
        #expect(attachmentCount(field) == 1)
        keyboard.deleteBackward()
        #expect(field.plainText == "hello world")
    }
}

