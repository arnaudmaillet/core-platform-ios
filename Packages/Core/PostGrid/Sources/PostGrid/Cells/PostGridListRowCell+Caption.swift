import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// The caption: measured at the layout's width, truncated with its Show more
extension PostGridListRowCell {
    func resolveMediaHeight(atWidth width: CGFloat) {
        if mediaPageCount > 1 {
            mediaHeight.constant = Self.collectionMediaHeight(
                forCardWidth: width, pageCount: mediaPageCount
            )
            return
        }
        mediaHeight.constant = Self.mediaHeight(
            forCardWidth: width, aspectRatio: mediaAspectRatio
        )
    }

    /// The ellipsis and the affordance, written INTO the caption so they sit at
    /// the end of the truncated text rather than under it.
    ///
    /// A label cannot do this for itself: `.byTruncatingTail` puts its ellipsis
    /// at the very end of the last line and leaves nowhere to put anything
    /// after it. So the text is shortened here, by hand, to the longest
    /// word-boundary prefix that still leaves room for "… Show more" on the
    /// last line — which is what makes the affordance read as part of the
    /// sentence it interrupts.
    func composeCaption(atWidth width: CGFloat) {
        let font = captionLabel.font ?? .appFont(forTextStyle: .body)
        let available = width - Self.captionInset * 2
        // A card of a FIXED height (`fixedCaptionLines`) offers no "Show more":
        // the label cuts its own tail with an ellipsis, and the whole card
        // opens the post.
        guard !isCaptionExpanded, fixedCaptionLines == nil, !fullCaption.isEmpty, available > 0 else {
            showMoreRange = nil
            captionLabel.attributedText = Self.plain(fullCaption, font: font)
            return
        }
        // Measured in LINES, from the font's own metrics — never a hardcoded
        // height, or a Dynamic Type step silently changes which captions are
        // considered long.
        let whole = Self.plain(fullCaption, font: font)
        guard Self.lineCount(whole, width: available) > Self.captionLineLimit else {
            showMoreRange = nil
            captionLabel.attributedText = whole
            return
        }
        let composed = Self.truncated(
            fullCaption, font: font, width: available, capLines: Self.captionLineLimit
        )
        captionLabel.attributedText = composed.text
        showMoreRange = composed.showMore
    }

    private static let showMoreTitle = "Show more"
    private static let ellipsis = "\u{2026} "

    /// The caption in the card's register, its emotes marked (`EmoteText`):
    /// a `:code:` is already the one glyph it draws as, so every measurement
    /// below sees the final line.
    static func plain(_ text: String, font: UIFont?) -> NSAttributedString {
        let caption = NSMutableAttributedString(attributedString: EmoteText.attributedString(text, attributes: attributes(font: font)))
        // `@handle`s and `#tag`s (#524), before anything is measured.
        caption.applyTextEntityStyle(.link)
        return caption
    }

    private static func attributes(font: UIFont?) -> [NSAttributedString.Key: Any] {
        [
            .font: font ?? UIFont.appFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ]
    }

    /// How many lines `text` occupies at `width`, counted as LINE FRAGMENTS.
    ///
    /// Not `height / font.lineHeight`, which is what this did first and is
    /// wrong in a way that hides: `boundingRect` returns the laid-out height
    /// including leading, which for four lines of body text measured 88pt
    /// against a 20.5pt line height — 4.29, not 4. Rounding rescues small
    /// counts and drifts into over-reporting as they grow, so the error only
    /// appears at large Dynamic Type sizes or long captions.
    static func lineCount(_ text: NSAttributedString, width: CGFloat) -> Int {
        guard text.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        var count = 0
        var index = 0
        while index < manager.numberOfGlyphs {
            var effective = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            count += 1
            index = NSMaxRange(effective)
        }
        return count
    }

    /// The longest word-boundary prefix of `text` whose last line still has
    /// room for "… Show more" AFTER it, plus the range that affordance
    /// occupies.
    ///
    /// Two steps, because the property wanted is not monotone and a single
    /// search cannot find it:
    ///
    /// 1. binary search for the longest prefix that fills at most `capLines` on
    ///    its own — this part IS monotone;
    /// 2. walk back a word at a time until the affordance fits on the same line
    ///    the prefix ends on.
    ///
    /// Searching in one step on "does the composition fit in `capLines`"
    /// instead — which is what this did first — maximises the wrong thing: a
    /// prefix filling three lines with the affordance wrapped alone onto a
    /// fourth satisfies it perfectly, and puts the affordance back on its own
    /// line, which is exactly what it exists to avoid. Caught by a test that
    /// counted the prefix's lines rather than the composition's.
    ///
    /// Word boundaries rather than characters: a caption cut mid-word reads as
    /// a rendering fault rather than as an interruption, and there are far
    /// fewer of them to search.
    private static func truncated(
        _ text: String, font: UIFont, width: CGFloat, capLines: Int
    ) -> (text: NSAttributedString, showMore: NSRange) {
        // Cut from the MARKED caption, so a `:code:` is one glyph that a word
        // boundary can never split, and the emotes a prefix keeps stay marked.
        let whole = plain(text, font: font)
        let ns = whole.string as NSString
        var boundaries: [Int] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            boundaries.append(range.location + range.length)
        }
        if boundaries.isEmpty { boundaries = [ns.length] }

        func prefix(upTo end: Int) -> NSAttributedString {
            let head = ns.substring(to: min(end, ns.length))
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let range = head.range(of: trimmed) else { return NSAttributedString() }
            return whole.attributedSubstring(from: NSRange(range, in: head))
        }
        func compose(_ prefix: NSAttributedString) -> NSAttributedString {
            let composed = NSMutableAttributedString(attributedString: prefix)
            composed.append(NSAttributedString(string: ellipsis, attributes: attributes(font: font)))
            composed.append(NSAttributedString(string: showMoreTitle, attributes: [
                .font: font,
                .foregroundColor: UIColor.tintColor
            ]))
            return composed
        }

        // 1. The longest prefix that fills at most `capLines` by itself.
        var low = 0
        var high = boundaries.count - 1
        var fullest = 0
        while low <= high {
            let mid = (low + high) / 2
            let candidate = prefix(upTo: boundaries[mid])
            if lineCount(candidate, width: width) <= capLines {
                fullest = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        // 2. Back off until the affordance shares the prefix's last line.
        var index = fullest
        while index >= 0 {
            let body = prefix(upTo: boundaries[index])
            let composed = compose(body)
            let bodyLines = lineCount(body, width: width)
            let composedLines = lineCount(composed, width: width)
            if composedLines == bodyLines, composedLines <= capLines {
                return (composed, showMoreRange(in: composed))
            }
            index -= 1
        }
        // Nothing fits beside it — a first word wider than the row. Show the
        // affordance alone rather than nothing at all.
        let composed = compose(prefix(upTo: boundaries[0]))
        return (composed, showMoreRange(in: composed))
    }

    static func showMoreRange(in composed: NSAttributedString) -> NSRange {
        NSRange(
            location: composed.length - (showMoreTitle as NSString).length,
            length: (showMoreTitle as NSString).length
        )
    }

    /// ⚠️ NOTHING IS FADED IN AT THE LANDING, and the deletion of the thing
    /// that used to be here is worth recording.
    ///
    /// The closing metric line was brought in over 0.22s once the card was
    /// alone, on the reasoning that the PAGE never had one — true of the
    /// reveal's push, and irrelevant to the leg this actually ran on. A
    /// dismissal's window carries `RevealDismissCardView`, which is a whole row
    /// including that line, so by the time this fired the viewer had been
    /// looking at the metric line for the length of the flight. Dropping it to
    /// zero and bringing it back is a blink of something already on screen —
    /// reported exactly that way.
    ///
    /// It is the same argument the band already won: the window shows a header
    /// identical to the row's, so the swap at the landing is the identity.
    /// Every part of this row now arrives that way.
}
