import CoreText
import UIKit

/// The TextKit layout an `EmoteLabel` both DRAWS and MEASURES with, so the
/// place an emote animates is the place its glyph was drawn — by construction,
/// not by agreement between two layout engines.
///
/// ⚠️ **WHY NOT MEASURE A PLAIN `UILabel`.** A label exposes no glyph rects,
/// and a TextKit mirror of its private layout can only ever approximate it: a
/// line-height rounding apart and the static glyph peeks out around the
/// animated one. So a label that holds emotes draws its text through this
/// layout instead, and one engine answers both questions.
@MainActor
final class EmoteTextLayout {
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer()

    /// Where one marked emote sits, in the layout's own coordinates (the text
    /// container's origin at 0,0).
    struct Placement: Equatable {
        /// The glyph's ink: what the label stops drawing once the animation
        /// covers it.
        let glyphBox: CGRect
        /// The square the animation is drawn in, centred on the glyph.
        let square: CGRect
    }

    init() {
        container.lineFragmentPadding = 0
        // `NSStringDrawing` — what `UILabel` and `boundingRect` use — does not
        // add font leading unless asked, and every caller in this app measures
        // without it.
        manager.usesFontLeading = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    private var configuredText: NSAttributedString?

    /// Lays `text` out in a box of `size`, at most `numberOfLines` lines (0 is
    /// unlimited), the last one broken by `lineBreakMode`.
    func configure(text: NSAttributedString, size: CGSize, numberOfLines: Int, lineBreakMode: NSLineBreakMode) {
        if configuredText !== text, configuredText?.isEqual(to: text) != true {
            storage.setAttributedString(text)
            configuredText = text
        }
        if container.size != size { container.size = size }
        if container.maximumNumberOfLines != numberOfLines { container.maximumNumberOfLines = numberOfLines }
        if container.lineBreakMode != lineBreakMode { container.lineBreakMode = lineBreakMode }
        manager.ensureLayout(for: container)
    }

    /// The size the laid-out text occupies.
    var usedSize: CGSize {
        manager.usedRect(for: container).size
    }

    /// Each mark's placement, or nil where the mark is not shown AS AN EMOJI:
    /// past the last line, inside the truncated tail, or drawn by a font that
    /// is not a colour-emoji font (a text-style fallback must stay text).
    func placements(for marks: [(range: NSRange, id: String)]) -> [Placement?] {
        let visible = manager.glyphRange(for: container)
        guard visible.length > 0 else { return marks.map { _ in nil } }
        // Glyphs from here on are replaced by the ellipsis.
        var truncatedFrom = Int.max
        let lastGlyph = NSMaxRange(visible) - 1
        let truncated = manager.truncatedGlyphRange(inLineFragmentForGlyphAt: lastGlyph)
        if truncated.location != NSNotFound { truncatedFrom = truncated.location }

        return marks.map { mark in
            guard NSMaxRange(mark.range) <= storage.length else { return nil }
            let glyphs = manager.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil)
            guard glyphs.length > 0,
                  glyphs.location >= visible.location,
                  NSMaxRange(glyphs) <= NSMaxRange(visible),
                  NSMaxRange(glyphs) <= truncatedFrom
            else { return nil }
            return placement(ofGlyph: glyphs.location, character: mark.range.location)
        }
    }

    private func placement(ofGlyph glyphIndex: Int, character: Int) -> Placement? {
        // The font the text system SUBSTITUTED for this character — Apple Color
        // Emoji for an emoji — not the one the caller asked for.
        storage.ensureAttributesAreFixed(in: NSRange(location: character, length: 1))
        guard let font = storage.attribute(.font, at: character, effectiveRange: nil) as? UIFont else { return nil }
        let ctFont = font as CTFont
        guard CTFontGetSymbolicTraits(ctFont).contains(.traitColorGlyphs) else { return nil }

        let line = manager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let location = manager.location(forGlyphAt: glyphIndex)
        let baseline = line.minY + location.y
        let penX = line.minX + location.x

        var glyph = manager.cgGlyph(at: glyphIndex)
        var ink = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyph, &ink, 1)
        let box: CGRect
        if ink.width > 0, ink.height > 0 {
            // Glyph space is y-up from the baseline; the layout is y-down.
            box = CGRect(x: penX + ink.minX, y: baseline - ink.maxY, width: ink.width, height: ink.height)
        } else {
            // No ink metrics: the advance, ascender to descender.
            let advance = manager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container
            ).width
            box = CGRect(x: penX, y: baseline - font.ascender, width: advance, height: font.ascender - font.descender)
        }
        guard box.width > 0, box.height > 0 else { return nil }
        let side = max(box.width, box.height)
        let square = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        return Placement(glyphBox: box, square: square)
    }

    /// Draws the laid-out text into the current context with the container's
    /// origin at `origin`, then erases each of `cleared` (in layout
    /// coordinates) — the glyphs an animation is covering.
    func draw(at origin: CGPoint, clearing cleared: [CGRect], scale: CGFloat) {
        let glyphs = manager.glyphRange(for: container)
        guard glyphs.length > 0 else { return }
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        guard !cleared.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        // One device pixel of outset takes the glyph's antialiased fringe too.
        let fringe = 1 / max(scale, 1)
        for box in cleared {
            context.clear(box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -fringe, dy: -fringe))
        }
    }
}
