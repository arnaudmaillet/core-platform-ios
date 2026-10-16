import Testing
import UIKit
@testable import Feed

/// The main-feed caption's two-line contract with the appended timestamp:
/// the time always trails the caption inline — on ONE line when both fit
/// there (2026-10-16), else at the end of line two — and a longer caption
/// truncates early so the time always sits un-clipped at the end.
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

    /// Case A: a short caption takes its time on the SAME line (the owner,
    /// 2026-10-16) — one line, so the block above comes down a line.
    @Test func aShortCaptionTakesItsTimeOnItsLine() {
        let composed = SnapChromeView.composedCaption("Golden hour.", timestamp: timestamp, width: width)
        #expect(composed.string == "Golden hour.  7\u{00A0}weeks")
        #expect(lineCount(composed) == 1)
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
    /// the end and the block is ALWAYS within two lines.
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
            #expect(lineCount(composed) <= 2)
        }
    }

    /// The GEOMETRY LOCK, per line: every line is one body line tall, so a
    /// one-line caption is exactly one body line and a two-line one exactly
    /// two — the smaller footnote time never shrinks the line it ends.
    @Test func captionContainerIsWholeBodyLines() {
        let bodyLineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let cases: [(String, Int)] = [
            ("Golden hour.", 1), // A — one line, time inline
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

    /// The timestamp reads as SECONDARY metadata: both DIMMER and in a
    /// SMALLER font register than the caption body, on every case.
    @Test func timestampRendersDimmerAndSmallerThanTheCaption() throws {
        for caption in ["Golden hour.", // Case A
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
            var tsAlpha: CGFloat = 0, capAlpha: CGFloat = 0
            tsColor.getWhite(nil, alpha: &tsAlpha)
            capColor.getWhite(nil, alpha: &capAlpha)
            #expect(tsAlpha < capAlpha)               // dimmer
            #expect(tsFont.pointSize < capFont.pointSize) // smaller register
        }
    }
}
