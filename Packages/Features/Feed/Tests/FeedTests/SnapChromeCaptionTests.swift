import Testing
import UIKit
@testable import Feed

/// The main-feed caption's strict two-line contract with the appended
/// timestamp: a single-line caption drops the timestamp to its own line, a
/// two-line caption takes it inline, and a longer caption truncates early so
/// the timestamp always sits un-clipped at the end of line two.
@MainActor
struct SnapChromeCaptionTests {
    /// A realistic live-cell caption width (390pt cell − two `lg` insets).
    private let width: CGFloat = 358
    private let timestamp = "7 weeks"

    private func lineCount(_ string: NSAttributedString) -> Int {
        SnapChromeView.captionLineCount(string, width: width)
    }

    /// Case A: a short caption fits one line, so the timestamp drops to its
    /// OWN second line — the composed string is exactly `caption\ntimestamp`,
    /// two lines total.
    @Test func singleLineCaptionDropsTheTimestampToItsOwnLine() {
        let composed = SnapChromeView.composedCaption("Golden hour.", timestamp: timestamp, width: width)
        #expect(composed.string == "Golden hour.\n7 weeks")
        #expect(lineCount(composed) == 2)
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
        #expect(composed.string.hasSuffix(timestamp))
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
        #expect(composed.string.hasSuffix(timestamp))
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
            #expect(composed.string.hasSuffix(timestamp))
            #expect(lineCount(composed) <= 2)
        }
    }

    /// The GEOMETRY LOCK: the composed caption block is exactly two body
    /// lines tall in EVERY case — the smaller timestamp on its own second
    /// line (Case A) can't collapse the container below the height of a
    /// two-line (Case B/C) caption. Measured height is identical across all
    /// three and equals two primary-font line heights.
    @Test func captionContainerHeightIsIdenticalAcrossCases() {
        let bodyLineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let cases = [
            "Golden hour.", // A — caption one line, timestamp drops below
            "Rebuilt the whole deploy pipeline over a slow rainy weekend.", // B — inline
            "Weekend build log: rebuilt the pipeline end to end, found two race conditions that only reproduce on cold caches, and learned more about backpressure than I ever wanted to.", // C — truncated
        ]
        let heights = cases.map { caption -> CGFloat in
            let composed = SnapChromeView.composedCaption(caption, timestamp: timestamp, width: width)
            return composed.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            ).height
        }
        // Every case is two body lines tall — neither collapsed toward one
        // (the Case A regression) nor grown to a third line (within half a
        // line of exactly two, after boundingRect's constant trailing
        // descent).
        for height in heights {
            #expect(height >= 2 * bodyLineHeight - 0.5)
            #expect(height < 2.5 * bodyLineHeight)
        }
        // …and FLAWLESSLY IDENTICAL to each other — the geometry lock's whole
        // point (every case ends on the footnote timestamp, so even the
        // trailing artifact matches).
        #expect(abs(heights[0] - heights[1]) < 0.5)
        #expect(abs(heights[1] - heights[2]) < 0.5)
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
