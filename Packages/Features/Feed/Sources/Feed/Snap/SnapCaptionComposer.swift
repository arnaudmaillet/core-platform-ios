import DesignSystem
import EmoteKit
import UIKit

/// The full-screen page's caption typography (#2521, out of `SnapChromeView`):
/// its register, its attributes and the two-line composition with the
/// post's age, shared by the live page and the flight's replica.
@MainActor
enum SnapCaptionComposer {
    /// The caption's register over the media, on every snap feed (#1697,
    /// #1708, the owner): one text style below the body (`.subheadline`).
    /// ONE register: it was a per-screen variant (the For You root's) until
    /// the owner gave it to every vertical feed.
    ///
    /// ⚠️ WHITE, NO GREY (#2012, the owner 2026-11-01): the app's standard
    /// text white over media — the subtitle zone's, the band's, a card's —
    /// FIXED, not the dynamic `.label` (black in light mode). The caption and
    /// its timestamp alike; the timestamp is set apart by its smaller
    /// `.footnote` alone. It was a 0.78 grey with a half-white timestamp
    /// (#1697), 3.4 : 1 over a bright picture under the scrim — under AA's
    /// 4.5 : 1, and dimmer than the comments around it.
    ///
    /// The AGE has its own ink since #2052 (the owner, 2026-11-02): a
    /// solid grey a little darker than the caption's white, so it steps
    /// back as metadata. Solid, not a translucent white, so the picture
    /// behind never shifts it; fixed, as the chrome is over media in both
    /// appearances. The caption itself stays white.
    enum CaptionRegister {
        static let textStyle: UIFont.TextStyle = .subheadline
        static let ink = UIColor.white
        static let timestampInk: UIColor = {
            #if DEBUG
            // `-caption-age-white 0.65`: the owner's device comparison (#2052).
            let white = UserDefaults.standard.double(forKey: "caption-age-white")
            if white > 0, white <= 1 { return UIColor(white: white, alpha: 1) }
            #endif
            return UIColor(white: 0.75, alpha: 1)
        }()
    }

    /// The caption typography — the shared attributes for the caption glyphs
    /// (`.body`) and, for `secondary`, the appended timestamp: a SMALLER
    /// `.footnote` register in its own grey (`timestampInk`, #2052), so it
    /// reads as secondary metadata by its size and ink (the same footnote register the
    /// engaged info card uses for the post age). Baked per-run so
    /// `boundingRect` measures each font's true footprint — the two-line
    /// truncation therefore accounts for the smaller timestamp automatically.
    /// The text shadow lives here (an `NSShadow` drawn WITH the glyphs)
    /// rather than as a `CALayer` shadow: a layer shadow on a full-width
    /// label has no `shadowPath` and costs an offscreen pass every scrolled
    /// frame.
    private static func captionAttributes(
        secondary: Bool
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.appFont(forTextStyle: secondary ? .footnote : CaptionRegister.textStyle),
            .foregroundColor: secondary ? CaptionRegister.timestampInk : CaptionRegister.ink,
            .shadow: captionTextShadow,
            // GEOMETRY LOCK: every line takes the PRIMARY (body) line height —
            // identical on every run — so a line ending on the smaller
            // footnote timestamp is still a full body line: the block is
            // exactly one or two body lines tall.
            .paragraphStyle: captionParagraphStyle,
        ]
    }

    /// The caption's soft text shadow over the media: half-black, a 3 pt
    /// blur, no offset. Worn too by the carousel's page counter, which has no
    /// plate since #2326. A new one each time: `NSShadow` is mutable.
    static var captionTextShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        return shadow
    }

    /// The shared paragraph style baked into every caption run. It pins the
    /// line height to the body font's (min == max) so mixed-font lines can't
    /// collapse, and keeps WORD WRAPPING — never a truncating mode — because
    /// `boundingRect` refuses to wrap under `.byTruncating*` (it would report
    /// one line for any width), and `composedCaption` already fits the text
    /// to two lines by construction, so the label needs no truncation of its
    /// own.
    private static var captionParagraphStyle: NSParagraphStyle {
        let bodyLineHeight = UIFont.appFont(forTextStyle: CaptionRegister.textStyle).lineHeight
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = bodyLineHeight
        paragraph.maximumLineHeight = bodyLineHeight
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }

    /// How many lines `string` occupies at `width` — the two-line contract's
    /// yardstick. A pure measurement (no label state), so `composedCaption`
    /// can probe candidate renderings before committing one.
    static func captionLineCount(
        _ string: NSAttributedString, width: CGFloat
    ) -> Int {
        guard width > 0, string.length > 0 else { return 0 }
        // No `.usesFontLeading`: the caption's paragraph style already locks
        // every line box to the body line height, so the measured height is a
        // clean multiple of it — adding per-font leading would only reintroduce
        // the mixed-font variance the lock exists to remove.
        let height = string.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        ).height
        let lineHeight = UIFont.appFont(forTextStyle: CaptionRegister.textStyle).lineHeight
        return max(1, Int((height / lineHeight).rounded()))
    }

    /// The single source of caption typography for every media post and both
    /// chrome instances (live cell + flight replica) — a PURE function of
    /// (text, timestamp, width) so both resolve identically. It enforces a
    /// two-line contract: the block is ALWAYS two lines tall, and the date
    /// is never on line one (#2252, the owner 2026-11-10):
    ///
    ///   • A one-line caption — the date ALONE on line two
    ///     (`Golden hour.` / `7 weeks`).
    ///   • Case B — a caption that runs onto line two takes the date inline
    ///     at that line's end (`…line two  7 weeks`).
    ///   • Case C — a longer caption truncates early on line two so the
    ///     ellipsis + date always sit un-clipped at that line's end
    ///     (`…cut off here…  7 weeks`).
    ///   • No caption (media only) — line one empty, reserved, and the date
    ///     on line two.
    ///
    /// ⚠️ CASE A IS GONE (#2252). A short caption took its date on its one
    /// line (`Golden hour.  7 weeks`, the owner 2026-10-16, #1256): the
    /// block was then one line tall and the stream above it came down a
    /// line — a second jump between posts, after the strip's seat. The
    /// block's bottom stands on the cover's line, so two lines on every post
    /// keep the author row, the stream and the danmaku still.
    ///
    /// With no timestamp (or an unmeasured zero width) it returns the bare
    /// caption — the label's own `numberOfLines`/truncation then applies, and
    /// the chrome's two-line floor (`captionBlockFloor`) keeps the height.
    ///
    /// Emotes are marked BEFORE anything is measured (`EmoteText`): a `:code:`
    /// is already the one emoji glyph it draws as, so every measurement below
    /// sees the final line, and Case C's bisection — which counts graphemes —
    /// can never cut an emote in half.
    static func composedCaption(
        _ caption: String, timestamp: String?, width: CGFloat
    ) -> NSAttributedString {
        let marked = NSMutableAttributedString(
            attributedString: EmoteText.attributedString(caption, attributes: captionAttributes(secondary: false))
        )
        // `@handle`s and `#tag`s in semibold, white like the rest over the
        // media (#524) — before anything is measured.
        marked.applyTextEntityStyle(.emphasis)
        let captionString: NSAttributedString = marked
        guard let timestamp, !timestamp.isEmpty, width > 0 else { return captionString }

        // ⚠️ ONE PIECE: "20 weeks" never splits across the two lines — the
        // inline time once ended line one with "20" and began line two with
        // "weeks" (seen on a device, 2026-10-16). Its spaces don't break.
        let unbroken = timestamp.replacingOccurrences(of: " ", with: "\u{00A0}")
        let timestampString = NSAttributedString(string: unbroken, attributes: captionAttributes(secondary: true))
        let gap = NSAttributedString(string: "  ", attributes: captionAttributes(secondary: false))

        // A caption on ONE line (or none): the date alone on line two, behind
        // a line break — never beside the caption on line one (#2252). Kept
        // only if it really is two lines, which a caption ending in a break
        // of its own might not be; else the cases below place the date.
        if captionString.length == 0 || captionLineCount(captionString, width: width) <= 1 {
            let stacked = NSMutableAttributedString(attributedString: captionString)
            stacked.append(NSAttributedString(string: "\n", attributes: captionAttributes(secondary: false)))
            stacked.append(timestampString)
            if captionLineCount(stacked, width: width) == 2 { return stacked }
        }

        // Case B: the caption runs onto line two, and its date follows it
        // there, inline.
        let inline = NSMutableAttributedString(attributedString: captionString)
        inline.append(gap)
        inline.append(timestampString)
        if captionLineCount(inline, width: width) <= 2 { return inline }

        // Case C: bisect for the longest caption prefix that keeps the
        // ellipsis + timestamp inside two lines (prefix length grows the
        // line count monotonically, so the largest fitting prefix is the
        // truncation point).
        let characters = Array(captionString.string)
        func candidate(prefixLength: Int) -> NSAttributedString {
            // Cut from the MARKED string, so the emotes a prefix keeps keep
            // their marks.
            let prefix = String(characters[0..<prefixLength])
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = NSMutableAttributedString()
            if !trimmed.isEmpty, let range = prefix.range(of: trimmed) {
                out.append(captionString.attributedSubstring(from: NSRange(range, in: prefix)))
            }
            out.append(NSAttributedString(string: "… ", attributes: captionAttributes(secondary: false)))
            out.append(timestampString)
            return out
        }
        var low = 0, high = characters.count, best = 0
        while low <= high {
            let mid = (low + high) / 2
            if captionLineCount(candidate(prefixLength: mid), width: width) <= 2 {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return candidate(prefixLength: best)
    }
}
