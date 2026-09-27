import EmoteKit
import Testing
import UIKit
@testable import Feed

/// The fullscreen caption's emotes: marked before the two-line contract
/// measures anything, and kept marked through every case.
@MainActor
struct SnapChromeCaptionEmoteTests {
    private let width: CGFloat = 358
    private let timestamp = "7 weeks"

    private func markedIDs(_ string: NSAttributedString) -> [String] {
        var ids: [String] = []
        string.enumerateAttribute(EmoteText.emoteAttribute, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let id = value as? String else { return }
            // One id per grapheme, as a run of identical emoji merges.
            let run = (string.string as NSString).substring(with: range)
            ids.append(contentsOf: Array(repeating: id, count: run.count))
        }
        return ids
    }

    /// Case A: codes replaced by their glyph, every emote marked, timestamp
    /// untouched.
    @Test func aShortCaptionMarksItsEmotes() {
        let composed = SnapChromeView.composedCaption("Trip 🔥 :lol:", timestamp: timestamp, width: width)
        #expect(composed.string == "Trip 🔥 😆\n7 weeks")
        #expect(markedIDs(composed) == ["noto:1f525", "lol"])
    }

    /// Case C cuts the MARKED string by graphemes: a code is never split into
    /// letters, and the emotes it keeps stay marked.
    @Test func truncationNeverSplitsAnEmote() {
        let caption = ":lol: " + String(repeating: "a long caption about the harbour ", count: 6) + ":lmao: end"
        let composed = SnapChromeView.composedCaption(caption, timestamp: timestamp, width: width)
        #expect(composed.string.contains("…"))
        #expect(composed.string.hasPrefix("😆"))
        #expect(!composed.string.contains(":"))
        #expect(markedIDs(composed) == ["lol"])
        #expect(SnapChromeView.captionLineCount(composed, width: width) <= 2)
    }

    /// Plain captions are byte-for-byte what they were.
    @Test func aPlainCaptionCarriesNoMarks() {
        let composed = SnapChromeView.composedCaption("Golden hour.", timestamp: timestamp, width: width)
        #expect(markedIDs(composed).isEmpty)
        #expect(composed.string == "Golden hour.\n7 weeks")
    }
}
