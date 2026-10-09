import Testing
import UIKit
@testable import Feed

/// A reply's quote rides the row's header line, right of the time (#753) —
/// not a line of its own above the row.
@MainActor
struct ThreadQuoteLineTests {
    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    private func makeCell(quote: (author: String, snippet: String)?) -> ThreadRowCell {
        let cell = ThreadRowCell(frame: CGRect(x: 0, y: 0, width: 358, height: 120))
        cell.row.setLikeControlHidden(true)
        cell.row.headerTextLabel.text = "You · 9:11 PM"
        cell.setQuote(quote)
        cell.layoutIfNeeded()
        return cell
    }

    @Test func theQuoteSitsRightOfTheTimeOnTheHeaderLine() throws {
        let cell = makeCell(quote: ("Ava Moreau", "Saw it. The thread screen rebuild is next, right? The list one is old."))
        let quote = try #require(Self.firstView(ThreadQuoteView.self, in: cell))
        let header = cell.row.headerTextLabel
        let quoteFrame = quote.convert(quote.bounds, to: cell)
        let headerFrame = header.convert(header.bounds, to: cell)
        let body = cell.row.bodyTextLabel.convert(cell.row.bodyTextLabel.bounds, to: cell)

        #expect(!quote.isHidden)
        #expect(abs(quoteFrame.midY - headerFrame.midY) < 2, "not on the header line: \(quoteFrame) vs \(headerFrame)")
        #expect(quoteFrame.minX >= headerFrame.maxX, "not right of the time")
        #expect(quoteFrame.maxY <= body.minY + 1, "the quote runs into the message")
        // The time keeps its full width: the quote is what truncates.
        let timeWidth = ceil(header.intrinsicContentSize.width)
        #expect(headerFrame.width >= timeWidth - 1, "the time truncated for the quote: \(headerFrame.width) < \(timeWidth)")
    }

    /// No quote: the header line is the row's alone, as before.
    @Test func noQuoteLeavesTheHeaderLineAlone() throws {
        let cell = makeCell(quote: nil)
        let quote = try #require(Self.firstView(ThreadQuoteView.self, in: cell))
        #expect(quote.isHidden)
        let withQuote = makeCell(quote: ("Ava", "hi"))
        #expect(abs(cell.row.bodyTextLabel.frame.minY - withQuote.row.bodyTextLabel.frame.minY) < 1,
                "the quote added a line")
    }
}
