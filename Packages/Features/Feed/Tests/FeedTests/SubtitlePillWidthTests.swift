import Testing
import UIKit
@testable import Feed

/// A wrapped cue's pill hugs its widest line (#1989): UILabel answers the
/// width it is offered once text wraps, and the pill is the label's own
/// fill, so it ran on far past the text.
@MainActor
struct SubtitlePillWidthTests {
    private static let font = UIFont.preferredFont(forTextStyle: .footnote)
    private static let insets = SubtitlePillLabel.textInsets.left + SubtitlePillLabel.textInsets.right

    private func label(_ text: String) -> SubtitlePillLabel {
        let label = SubtitlePillLabel()
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.font = Self.font
        label.text = text
        return label
    }

    /// The widest of the lines `text` breaks into at `width`.
    private func widestLine(_ text: String, at width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: Self.font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 2
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var widest: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, used, _, _, _ in
            widest = max(widest, used.width)
        }
        return widest
    }

    /// The owner's cue: two lines at the zone's width, and a pill as wide as
    /// the first of them plus its insets — not the whole width.
    @Test func aWrappedCueHugsItsWidestLine() {
        let text = "The pacing on that last cut is genuinely perfect."
        let available: CGFloat = 230
        let label = label(text)
        let rect = label.textRect(forBounds: CGRect(x: 0, y: 0, width: available, height: 200), limitedToNumberOfLines: 2)
        let widest = widestLine(text, at: available - Self.insets)
        #expect(rect.width < available - 4, "the pill took \(rect.width) of \(available)")
        #expect(abs(rect.width - (widest + Self.insets)) <= 2, "\(rect.width) vs widest line \(widest)")
    }

    /// At its own tight width the text breaks the same way: still two lines,
    /// never a third, never shorter.
    @Test func theTightWidthKeepsTheBreaks() {
        let text = "The pacing on that last cut is genuinely perfect."
        let label = label(text)
        let wide = label.textRect(forBounds: CGRect(x: 0, y: 0, width: 230, height: 200), limitedToNumberOfLines: 2)
        let tight = label.textRect(forBounds: CGRect(x: 0, y: 0, width: wide.width, height: 200), limitedToNumberOfLines: 2)
        #expect(tight.height == wide.height)
        #expect(abs(tight.width - wide.width) <= 1)
    }

    /// A one-line cue keeps its own width, as before.
    @Test func aOneLineCueIsUnchanged() {
        let label = label("so clean")
        let natural = label.textRect(forBounds: CGRect(x: 0, y: 0, width: 10_000, height: 200), limitedToNumberOfLines: 2)
        let offered = label.textRect(forBounds: CGRect(x: 0, y: 0, width: 230, height: 200), limitedToNumberOfLines: 2)
        #expect(abs(natural.width - offered.width) < 0.5)
    }
}
