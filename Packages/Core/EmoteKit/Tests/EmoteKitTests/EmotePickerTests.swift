import Foundation
import Testing
import UIKit
@testable import EmoteKit

/// The pure rules of composing: insertion, deletion, inline queries, sections.
@Suite(.sharesMainThread)
struct EmoteComposingTests {
    private let catalog = EmoteCatalog.shared

    @Test func insertionLandsAtTheCaretAndMovesIt() {
        let (text, caret) = EmoteComposing.inserting(":lol:", into: "hello world", replacing: NSRange(location: 5, length: 0))
        #expect(text == "hello:lol: world")
        #expect(caret == 10)
    }

    @Test func insertionReplacesTheSelection() {
        let (text, caret) = EmoteComposing.inserting("🔥", into: "so cold", replacing: NSRange(location: 3, length: 4))
        #expect(text == "so 🔥")
        #expect(caret == 5) // 🔥 is two UTF-16 units
    }

    @Test func anOutOfRangeCaretIsClampedNotATrap() {
        #expect(EmoteComposing.inserting("x", into: "ab", replacing: NSRange(location: 99, length: 5)).text == "abx")
    }

    /// Backspace takes a whole code or a whole emoji — never half of either.
    @Test func backspaceTakesWholeEmotes() {
        let code = "ha :lol:"
        #expect(EmoteComposing.deletionRange(in: code, caret: 8, catalog: catalog) == NSRange(location: 3, length: 5))
        let tone = "ok 👍🏽"
        #expect(EmoteComposing.deletionRange(in: tone, caret: (tone as NSString).length, catalog: catalog)
            == NSRange(location: 3, length: 4))
        // An unknown code is plain text: one character.
        #expect(EmoteComposing.deletionRange(in: ":nope:", caret: 6, catalog: catalog) == NSRange(location: 5, length: 1))
        #expect(EmoteComposing.deletionRange(in: "", caret: 0, catalog: catalog) == nil)
    }

    @Test func anInlineQueryOpensAWord() throws {
        let hit = try #require(EmoteComposing.inlineQuery(in: "gg :lau", caret: 7))
        #expect(hit.query == "lau")
        #expect(hit.range == NSRange(location: 3, length: 4))
        #expect(EmoteComposing.inlineQuery(in: ":fi", caret: 3)?.query == "fi")
        // After an emoji (two UTF-16 units) or punctuation, a colon opens a word.
        #expect(EmoteComposing.inlineQuery(in: "😂:fi", caret: 5)?.query == "fi")
        #expect(EmoteComposing.inlineQuery(in: "(:fi", caret: 4)?.query == "fi")
        // One letter is not a search yet; a time, a URL and a word glued to
        // the colon never are.
        #expect(EmoteComposing.inlineQuery(in: "gg :l", caret: 5) == nil)
        #expect(EmoteComposing.inlineQuery(in: "at 10:30", caret: 8) == nil)
        #expect(EmoteComposing.inlineQuery(in: "http://ab", caret: 9) == nil)
        #expect(EmoteComposing.inlineQuery(in: "word:lau", caret: 8) == nil)
        // Only what is right before the caret counts.
        #expect(EmoteComposing.inlineQuery(in: ":lau then", caret: 9) == nil)
        // A finished code is not a query.
        #expect(EmoteComposing.inlineQuery(in: ":lol:", caret: 5) == nil)
    }

    @Test func suggestionsPutMatchingCodesFirst() throws {
        let suggestions = EmoteComposing.suggestions(for: "lo", catalog: catalog)
        #expect(suggestions.first?.id == "lol")
        let fire = EmoteComposing.suggestions(for: "fire", catalog: catalog)
        #expect(fire.contains { $0.id == "noto:1f525" })
        #expect(EmoteComposing.suggestions(for: "zzqq", catalog: catalog).isEmpty)
        #expect(EmoteComposing.suggestions(for: "a", catalog: catalog, limit: 5).count <= 5)
    }

    @Test func recentComesFirstThenHouseThenNoto() throws {
        let fire = try #require(catalog.emote(id: "noto:1f525"))
        let sections = EmoteComposing.sections(catalog: catalog, recents: [fire])
        #expect(sections.map(\.id).prefix(3) == ["recent", "house", "smileys"])
        #expect(sections[0].emotes == [fire])
        #expect(EmoteComposing.sections(catalog: catalog, recents: []).first?.id == "house")
        #expect(sections.allSatisfy { !$0.emotes.isEmpty })
    }
}

/// Recents: order, dedup, limit, and persistence across launches.
@MainActor
@Suite(.sharesMainThread)
struct EmoteRecentsTests {
    private let catalog = EmoteCatalog.shared

    private func scratchDefaults() -> UserDefaults {
        let name = "emote-recents-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func recentsAreMostRecentFirstWithoutDuplicates() throws {
        let recents = EmoteRecents(defaults: scratchDefaults())
        let fire = try #require(catalog.emote(id: "noto:1f525"))
        let lol = try #require(catalog.emote(id: "lol"))
        recents.record(fire)
        recents.record(lol)
        recents.record(fire)
        #expect(recents.ids == ["noto:1f525", "lol"])
    }

    @Test func recentsSurviveARelaunchAndStayBounded() throws {
        let defaults = scratchDefaults()
        let first = EmoteRecents(defaults: defaults)
        for emote in catalog.all.prefix(EmoteRecents.limit + 5) { first.record(emote) }
        #expect(first.ids.count == EmoteRecents.limit)
        let relaunched = EmoteRecents(defaults: defaults)
        #expect(relaunched.ids == first.ids)
        #expect(relaunched.emotes(in: catalog).count == EmoteRecents.limit)
    }

    /// An id this build no longer ships is skipped, not a crash.
    @Test func unknownIDsAreSkipped() {
        let defaults = scratchDefaults()
        defaults.set(["gone-forever", "lol"], forKey: "emote.recents.v1")
        #expect(EmoteRecents(defaults: defaults).emotes(in: catalog).map(\.id) == ["lol"])
    }
}

/// The keyboard controller on a real text view: panel picks, inline search,
/// backspace, and the delegate told like typing.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteKeyboardTests {
    private let catalog = EmoteCatalog.shared

    private final class Delegate: NSObject, UITextViewDelegate {
        var changes = 0
        func textViewDidChange(_ textView: UITextView) { changes += 1 }
    }

    private func make(_ text: String, caret: Int) -> (UITextView, EmoteKeyboard, EmoteRecents, Delegate) {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        textView.text = text
        textView.selectedRange = NSRange(location: caret, length: 0)
        let delegate = Delegate()
        textView.delegate = delegate
        let recents = EmoteRecents(defaults: UserDefaults(suiteName: "emote-keyboard-\(UUID().uuidString)")!)
        let keyboard = EmoteKeyboard(textView: textView, engine: EmoteEngine(diskCache: nil), recents: recents)
        return (textView, keyboard, recents, delegate)
    }

    @Test func aPanelPickInsertsAtTheCaretAndIsRemembered() throws {
        let (textView, keyboard, recents, delegate) = make("hello world", caret: 5)
        let lol = try #require(catalog.emote(id: "lol"))
        keyboard.pick(lol)
        #expect(textView.text == "hello:lol: world")
        #expect(textView.selectedRange == NSRange(location: 10, length: 0))
        #expect(delegate.changes == 1)
        #expect(recents.ids == ["lol"])

        let fire = try #require(catalog.emote(id: "noto:1f525"))
        keyboard.pick(fire)
        #expect(textView.text == "hello:lol:🔥 world")
        #expect(recents.ids == ["noto:1f525", "lol"])
    }

    @Test func thePanelTapGoesThroughItsCells() throws {
        let (textView, keyboard, _, _) = make("", caret: 0)
        let panel = keyboard.panel
        panel.reload(recents: [])
        #expect(panel.sectionTitles.first == EmoteSection.house.title)
        panel.select(IndexPath(item: 0, section: 0))
        #expect(textView.text == EmoteCatalog.house[0].insertionText)
    }

    @Test func typingAQueryOffersEmotesAndATapReplacesIt() throws {
        let (textView, keyboard, recents, _) = make("", caret: 0)
        textView.text = "gg :lo"
        textView.selectedRange = NSRange(location: 6, length: 0)
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: textView)
        #expect(keyboard.suggestionIDs.first == "lol")
        keyboard.selectSuggestion(at: 0)
        #expect(textView.text == "gg :lol:")
        #expect(keyboard.suggestionIDs.isEmpty)
        #expect(recents.ids == ["lol"])
    }

    @Test func theMagnifierStartsAQueryThatOpensAWord() {
        let (textView, keyboard, _, _) = make("hey", caret: 3)
        keyboard.search()
        #expect(textView.text == "hey :")
        #expect(textView.selectedRange.location == 5)
    }

    /// After an emoji the colon already opens a word: no space is added.
    @Test func theMagnifierNeedsNoSpaceAfterAnEmoji() {
        let (textView, keyboard, _, _) = make("gg 😂", caret: 5)
        keyboard.search()
        #expect(textView.text == "gg 😂:")
    }

    @Test func backspaceDeletesAWholeCode() {
        let (textView, keyboard, _, delegate) = make("ha :lol:", caret: 8)
        keyboard.deleteBackward()
        #expect(textView.text == "ha ")
        #expect(delegate.changes == 1)
    }

    /// A delegate that refuses the change keeps the text as it was.
    @Test func theDelegateCanVetoAnInsertion() throws {
        final class Refusing: NSObject, UITextViewDelegate {
            func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
                false
            }
        }
        let (textView, keyboard, _, _) = make("full", caret: 4)
        let refusing = Refusing()
        textView.delegate = refusing
        keyboard.pick(try #require(catalog.emote(id: "lol")))
        #expect(textView.text == "full")
    }
}

/// The panel stands in for the system keyboard at EXACTLY its height, so a
/// composer riding the keyboard does not move on the swap.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteKeyboardHeightTests {
    private let screen = CGRect(x: 0, y: 0, width: 402, height: 874)

    private func scratch() -> (EmoteKeyboardHeight, UserDefaults) {
        let defaults = UserDefaults(suiteName: "emote-keyboard-height-\(UUID().uuidString)")!
        return (EmoteKeyboardHeight(defaults: defaults), defaults)
    }

    private func docked(_ height: CGFloat, width: CGFloat = 402, screenHeight: CGFloat = 874) -> CGRect {
        CGRect(x: 0, y: screenHeight - height, width: width, height: height)
    }

    @Test func aDockedSystemKeyboardIsMeasuredPerWidthAndPersisted() {
        let (heights, defaults) = scratch()
        #expect(heights.record(endFrame: docked(336), screen: screen))
        #expect(heights.height(screenSize: screen.size, bottomInset: 34) == 336)
        // Landscape is its own measurement.
        let landscape = CGRect(x: 0, y: 0, width: 874, height: 402)
        #expect(heights.measuredHeight(screenWidth: 874) == nil)
        #expect(heights.record(endFrame: docked(209, width: 874, screenHeight: 402), screen: landscape))
        #expect(heights.height(screenSize: landscape.size, bottomInset: 21) == 209)
        #expect(heights.height(screenSize: screen.size, bottomInset: 34) == 336)
        // The next launch opens the panel at the measured height.
        let relaunched = EmoteKeyboardHeight(defaults: defaults)
        #expect(relaunched.measuredHeight(screenWidth: 402) == 336)
        #expect(relaunched.measuredHeight(screenWidth: 874) == 209)
    }

    @Test func framesThatAreNotADockedKeyboardAreIgnored() {
        let (heights, _) = scratch()
        // Leaving: the end frame is below the screen.
        #expect(!heights.record(endFrame: CGRect(x: 0, y: 874, width: 402, height: 336), screen: screen))
        // A hardware keyboard's shortcut bar.
        #expect(!heights.record(endFrame: docked(55), screen: screen))
        // Undocked: does not reach the bottom.
        #expect(!heights.record(endFrame: CGRect(x: 0, y: 300, width: 402, height: 300), screen: screen))
        // Narrower than the screen (a floating keyboard).
        #expect(!heights.record(endFrame: CGRect(x: 50, y: 574, width: 300, height: 300), screen: screen))
        #expect(heights.measuredHeight(screenWidth: 402) == nil)
    }

    /// While the panel is up, the frame the system reports is the PANEL's:
    /// it must not be taken for the keyboard's.
    @Test func thePanelsOwnFrameIsNotMeasured() {
        let (heights, defaults) = scratch()
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        let keyboard = EmoteKeyboard(
            textView: textView, engine: EmoteEngine(diskCache: nil),
            recents: EmoteRecents(defaults: defaults), suggestsInline: false, heights: heights
        )
        textView.inputView = keyboard.panel
        #expect(keyboard.isShowingPanel)
        #expect(!heights.record(endFrame: docked(300), screen: screen))
        textView.inputView = nil
        #expect(heights.record(endFrame: docked(336), screen: screen))
        #expect(heights.measuredHeight(screenWidth: 402) == 336)
    }

    /// Before any keyboard was ever seen: the stock keyboard of the device.
    @Test func theDefaultIsTheDevicesStockKeyboard() {
        // Face ID Pro, portrait: measured 328 on the iOS 27 simulator.
        #expect(EmoteKeyboardHeight.defaultHeight(screenSize: CGSize(width: 402, height: 874), bottomInset: 34) == 328)
        // Touch ID SE: no inset, a shorter keyboard.
        #expect(EmoteKeyboardHeight.defaultHeight(screenSize: CGSize(width: 375, height: 667), bottomInset: 0) == 260)
        // A Pro Max is a little taller; landscape is shallower.
        #expect(EmoteKeyboardHeight.defaultHeight(screenSize: CGSize(width: 440, height: 956), bottomInset: 34) == 338)
        #expect(EmoteKeyboardHeight.defaultHeight(screenSize: CGSize(width: 874, height: 402), bottomInset: 21) < 260)
    }

    /// The panel takes the measured height, asks for it through its intrinsic
    /// size (it self-sizes), and its grid is the whole panel with the section
    /// bar floating over it, clear of the last row.
    @Test func thePanelIsTheKeyboardsHeightWithAFullHeightGridUnderAFloatingBar() throws {
        let (heights, _) = scratch()
        let window = UIWindow(frame: screen)
        window.isHidden = false
        defer {
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
            window.layoutIfNeeded()
        }
        let screenBounds = window.screen.bounds
        heights.record(endFrame: CGRect(x: 0, y: screenBounds.maxY - 336, width: screenBounds.width, height: 336),
                       screen: screenBounds)
        let panel = EmotePickerView(engine: EmoteEngine(diskCache: nil), heights: heights)
        panel.reload(recents: [])
        panel.matchKeyboardHeight(in: window)
        #expect(panel.panelHeight == 336)
        #expect(panel.intrinsicContentSize.height == 336)
        #expect(panel.allowsSelfSizing)

        panel.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: 336)
        window.addSubview(panel)
        panel.layoutIfNeeded()
        let grid = panel.collectionView
        #expect(grid.frame.minY == 0)
        #expect(grid.frame.maxY == panel.bounds.maxY, "the grid runs under the bar to the panel's bottom")
        let bar = panel.sectionBarGlass.frame
        #expect(bar.maxY <= panel.bounds.maxY && bar.minY > grid.frame.minY)
        #expect(grid.contentInset.bottom >= panel.bounds.maxY - bar.minY, "the last row scrolls clear of the bar")
        #expect(panel.sectionBarGlass.effect is UIGlassEffect, "glass, not a slab")
        #expect(panel.sectionBarGlass.backgroundColor == nil)
    }
}
