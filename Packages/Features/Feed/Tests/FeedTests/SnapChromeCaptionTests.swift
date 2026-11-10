import Testing
import UIKit
@testable import Feed

/// The main-feed caption's two-line contract with the appended timestamp
/// (#2252): the block is ALWAYS two lines tall and the date is never on line
/// one — alone on line two after a one-line caption (or none), inline at the
/// end of line two after a longer one — and a caption longer still truncates
/// early so the date always sits un-clipped at the end.
@MainActor
struct SnapChromeCaptionTests {
    /// A realistic live-cell caption width (390pt cell − two `lg` insets).
    private let width: CGFloat = 358
    private let timestamp = "7 weeks"
    /// The time as the caption draws it: one piece (a no-break space).
    private let shownTime = "7\u{00A0}weeks"

    private func lineCount(_ string: NSAttributedString) -> Int {
        SnapChromeView.captionLineCount(string, width: width)
    }

    /// (#2252) A one-line caption puts the date ALONE on line two: the block
    /// is two lines tall, so nothing above it comes down. (Case A — the date
    /// inline on the caption's one line, the owner 2026-10-16 — is gone.)
    @Test func aOneLineCaptionPutsTheDateAloneOnLineTwo() {
        let composed = SnapChromeView.composedCaption("Golden hour.", timestamp: timestamp, width: width)
        #expect(composed.string == "Golden hour.\n\(shownTime)")
        #expect(lineCount(composed) == 2)
        // The date is all of line two: nothing of the caption followed it.
        #expect(composed.string.components(separatedBy: "\n").last == shownTime)
    }

    /// (#2252) No caption (media only): line one empty and reserved, the
    /// date on line two — still two lines, so the author row over it holds.
    @Test func noCaptionGivesTheDateOnLineTwo() {
        let composed = SnapChromeView.composedCaption("", timestamp: timestamp, width: width)
        #expect(composed.string == "\n\(shownTime)")
        #expect(lineCount(composed) == 2)
    }

    /// (#2252) The date is never on line one, whatever the caption's length
    /// and the width — a one-line caption sends it down a line, a longer one
    /// keeps it at line two's end — and the block is always two lines.
    /// Across widths, as a stand-in for Dynamic Type too: a larger caption
    /// font wraps a caption the way a narrower column does, and the
    /// composition measures at the font it draws in.
    @Test func theDateIsNeverOnLineOne() {
        let captions = [
            "", "Hi.", "Golden hour.", "New city, same habits.",
            "Rebuilt the whole deploy pipeline over a slow rainy weekend.",
            "Weekend build log: rebuilt the pipeline end to end, found two race conditions that only reproduce on cold caches, and learned more about backpressure than I ever wanted to.",
        ]
        for width: CGFloat in stride(from: 160, through: 400, by: 20) {
            for caption in captions {
                let composed = SnapChromeView.composedCaption(caption, timestamp: timestamp, width: width)
                #expect(SnapChromeView.captionLineCount(composed, width: width) == 2, "\(width): \(caption)")
                #expect(composed.string.hasSuffix(shownTime), "\(width): \(caption)")
                // Line one, as the label lays it out, holds no part of the date.
                let firstLine = Self.firstLine(of: composed, width: width)
                #expect(!firstLine.contains(shownTime) && !firstLine.contains("weeks"), "\(width): \(caption) → \(firstLine)")
            }
        }
    }

    /// The text of the first line `string` lays out on at `width`, through
    /// TextKit the way a label wraps it.
    private static func firstLine(of string: NSAttributedString, width: CGFloat) -> String {
        let storage = NSTextStorage(attributedString: string)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        guard layout.numberOfGlyphs > 0 else { return "" }
        var range = NSRange()
        layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: &range)
        let characters = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
        return (string.string as NSString).substring(with: characters)
    }

    /// The time is one piece: whatever the caption's length, "7 weeks" is
    /// never split across the lines (its space does not break).
    @Test func theTimeNeverSplitsAcrossLines() {
        let caption = "Golden hour at the pier. #goldenhour"
        for width: CGFloat in stride(from: 200, through: 360, by: 4) {
            let composed = SnapChromeView.composedCaption(caption, timestamp: timestamp, width: width)
            #expect(composed.string.hasSuffix("7\u{00A0}weeks"), "width \(width)")
        }
    }

    /// Case B: a caption that naturally wraps to two lines but leaves room
    /// takes the timestamp INLINE at the end of line two — no newline, no
    /// ellipsis, and still within two lines.
    @Test func twoLineCaptionAppendsTheTimestampInline() {
        let caption = "Rebuilt the whole deploy pipeline over a slow rainy weekend."
        let composed = SnapChromeView.composedCaption(caption, timestamp: timestamp, width: width)
        // The full caption is present (nothing truncated) and the timestamp
        // trails it on the same block, within two lines.
        #expect(composed.string.contains(caption))
        #expect(composed.string.hasSuffix(shownTime))
        #expect(!composed.string.contains("\n"))
        #expect(!composed.string.contains("…"))
        #expect(lineCount(composed) <= 2)
        // Precondition of Case B: the bare caption really is a two-line one.
        let bare = SnapChromeView.composedCaption(caption, timestamp: nil, width: width)
        #expect(lineCount(bare) == 2)
    }

    /// Case C: a long caption truncates early on line two — an ellipsis then
    /// the timestamp, both un-clipped, and the whole thing held to two lines.
    /// The surviving caption text is a genuine prefix of the original.
    @Test func longCaptionTruncatesLeavingRoomForTheTimestamp() {
        let caption = "Weekend build log: rebuilt the pipeline end to end, found two race conditions that only reproduce on cold caches, and learned more about backpressure than I ever wanted to."
        let composed = SnapChromeView.composedCaption(caption, timestamp: timestamp, width: width)
        #expect(composed.string.hasSuffix(shownTime))
        #expect(composed.string.contains("…"))
        #expect(!composed.string.contains("\n"))
        #expect(lineCount(composed) <= 2)
        // The kept caption text (before the ellipsis) is a real prefix — we
        // trimmed the original, never rewrote it.
        let head = String(composed.string.components(separatedBy: "…").first ?? "")
            .trimmingCharacters(in: .whitespaces)
        #expect(!head.isEmpty)
        #expect(caption.hasPrefix(head))
        // …and it genuinely shortened the caption (the full caption alone
        // already overran two lines).
        let bare = SnapChromeView.composedCaption(caption, timestamp: nil, width: width)
        #expect(lineCount(bare) > 2)
        #expect(head.count < caption.count)
    }

    /// The invariant across every length: the timestamp is ALWAYS present at
    /// the end and the block is ALWAYS exactly two lines (#2252).
    @Test func everyCompositionEndsWithTheTimestampWithinTwoLines() {
        let captions = [
            "Hi.",
            "New city, same habits.",
            "Rebuilt the whole deploy pipeline over a slow rainy weekend.",
            "Weekend build log: rebuilt the pipeline end to end, found two race conditions that only reproduce on cold caches, and learned more about backpressure than I ever wanted to know in one sitting.",
        ]
        for caption in captions {
            let composed = SnapChromeView.composedCaption(caption, timestamp: timestamp, width: width)
            #expect(composed.string.hasSuffix(shownTime))
            #expect(lineCount(composed) == 2)
        }
    }

    /// The GEOMETRY LOCK, per line: every line is one caption line tall (the
    /// caption's register, `.subheadline` since #1708), and every block is
    /// exactly two (#2252) — the smaller footnote time never shrinks the line
    /// it ends, even alone on it.
    @Test func captionContainerIsWholeBodyLines() {
        let bodyLineHeight = UIFont.appFont(forTextStyle: SnapChromeView.CaptionRegister.textStyle).lineHeight
        let cases: [(String, Int)] = [
            ("Golden hour.", 2), // the date alone on line two (#2252)
            ("", 2), // no caption: line one empty, the date on line two
            ("Rebuilt the whole deploy pipeline over a slow rainy weekend.", 2), // B — inline on line two
            ("Weekend build log: rebuilt the pipeline end to end, found two race conditions that only reproduce on cold caches, and learned more about backpressure than I ever wanted to.", 2), // C — truncated
        ]
        for (caption, lines) in cases {
            let composed = SnapChromeView.composedCaption(caption, timestamp: timestamp, width: width)
            let height = composed.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            ).height
            #expect(height >= CGFloat(lines) * bodyLineHeight - 0.5, "\(caption)")
            #expect(height < (CGFloat(lines) + 0.5) * bodyLineHeight, "\(caption)")
        }
    }

    /// No timestamp (or an unmeasured zero width) → the bare caption, so the
    /// label's own line cap and truncation apply unchanged.
    @Test func withoutATimestampTheCaptionIsUnchanged() {
        let caption = "Rebuilt the whole deploy pipeline over a slow rainy weekend."
        #expect(SnapChromeView.composedCaption(caption, timestamp: nil, width: width).string == caption)
        #expect(SnapChromeView.composedCaption(caption, timestamp: "", width: width).string == caption)
        #expect(SnapChromeView.composedCaption(caption, timestamp: timestamp, width: 0).string == caption)
    }

    /// (#1697, #1708, #2012): every snap feed's caption is one text style
    /// below the body (`.subheadline`) in the app's standard white — no grey
    /// since #2012 — its time the smaller register, and the two-line
    /// contract holds at its size.
    @Test func theCaptionIsSmallerAndWhiteAndKeepsTheContract() throws {
        let caption = "Weekend build log: rebuilt the pipeline end to end, found two race conditions that only reproduce on cold caches, and learned more about backpressure than I ever wanted to."
        let soft = SnapChromeView.composedCaption(caption, timestamp: timestamp, width: width)
        let softFont = try #require(soft.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(softFont.pointSize == UIFont.appFont(forTextStyle: .subheadline).pointSize, "not the subheadline register")
        #expect(softFont.pointSize < UIFont.appFont(forTextStyle: .body).pointSize, "the caption is not smaller than the body")
        let softInk = try #require(soft.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        var white: CGFloat = 0, alpha: CGFloat = 0
        softInk.getWhite(&white, alpha: &alpha)
        #expect(white == 1 && alpha == 1, "the caption is not white: \(white), \(alpha)")
        let timeFont = try #require(soft.attribute(.font, at: soft.length - 1, effectiveRange: nil) as? UIFont)
        #expect(timeFont.pointSize < softFont.pointSize, "the time is not the smaller register")
        #expect(SnapChromeView.captionLineCount(soft, width: width) <= 2)
        #expect(soft.string.hasSuffix(timestamp.replacingOccurrences(of: " ", with: "\u{00A0}")))
    }

    /// The timestamp reads as SECONDARY metadata by its SMALLER font register
    /// and its own solid grey (#2052, the owner: a little darker than the
    /// caption), on every case; the caption keeps its white (#2012).
    @Test func timestampRendersSmallerInItsOwnGrey() throws {
        for caption in ["Golden hour.", // the date alone on line two (#2252)
                        "Rebuilt the whole deploy pipeline over a slow rainy weekend.", // Case B
                        "Weekend build log: rebuilt the pipeline end to end, found two race conditions that only reproduce on cold caches, and learned more about backpressure than I ever wanted to."] { // Case C
            let composed = SnapChromeView.composedCaption(caption, timestamp: timestamp, width: width)
            // The timestamp glyphs live at the tail — probe the last character.
            let tsIndex = composed.length - 1
            let tsColor = try #require(
                composed.attribute(.foregroundColor, at: tsIndex, effectiveRange: nil) as? UIColor
            )
            let tsFont = try #require(composed.attribute(.font, at: tsIndex, effectiveRange: nil) as? UIFont)
            let capColor = try #require(
                composed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
            )
            let capFont = try #require(composed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
            #expect(tsColor == SnapChromeView.CaptionRegister.timestampInk, "the time is not in its own ink")
            #expect(capColor == SnapChromeView.CaptionRegister.ink, "the caption is not white")
            var white: CGFloat = 0, alpha: CGFloat = 0
            tsColor.getWhite(&white, alpha: &alpha)
            #expect(white == 0.75 && alpha == 1, "the time is not the solid 0.75 grey: \(white), \(alpha)")
            // The gap before the time is a caption run, in the caption's white.
            let gapIndex = composed.length - shownTime.count - 1
            let gapColor = composed.attribute(.foregroundColor, at: gapIndex, effectiveRange: nil) as? UIColor
            #expect(gapColor == SnapChromeView.CaptionRegister.ink)
            #expect(tsFont.pointSize < capFont.pointSize) // smaller register
        }
    }
}
