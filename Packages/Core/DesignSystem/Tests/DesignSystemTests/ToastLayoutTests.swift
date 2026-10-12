import Testing
import UIKit
@testable import DesignSystem

/// The toast's one-line layout (#1034): one line of text, a toast with an
/// action as wide as the margins allow with its control flush trailing, one
/// without hugging its text; 48 pt with an action, 44 pt without.
@MainActor
@Suite(.serialized)
struct ToastLayoutTests {
    private func hosting(_ body: (UIWindow, UIView) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.layoutIfNeeded()
        let (clock, _) = ToastClock.manual()
        let previousClock = ToastClock.current
        ToastClock.current = clock
        defer {
            ToastClock.current = previousClock
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body(window, window.rootViewController!.view)
    }

    private func undoable(_ message: String, in container: UIView) -> ToastView {
        ToastView.present(
            message, symbol: "trash.fill", style: .confirmation,
            undoable: ToastView.Undoable(commit: {}, undo: {}), position: .bottom, in: container
        )
    }

    private func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels(in: $0) }
    }

    private func settled(_ container: UIView) {
        container.setNeedsLayout()
        container.layoutIfNeeded()
    }

    /// With an action, as wide as the margins allow — and Undo at the
    /// trailing edge, not mid-capsule.
    @Test func anUndoToastSpansTheMarginsWithItsControlTrailing() throws {
        try hosting { _, container in
            let toast = undoable("Post deleted", in: container)
            settled(container)
            let margins = container.layoutMarginsGuide.layoutFrame.width
            #expect(abs(toast.bounds.width - min(margins, ToastView.Metrics.maximumWidth)) < 1)
            let control = try #require(toast.undoButton)
            let trailing = toast.bounds.maxX - control.convert(control.bounds, to: toast).maxX
            #expect(trailing <= Spacing.sm + 1, "\(trailing) pt after the control")
        }
    }

    /// Without one, the capsule hugs its text.
    @Test func aPlainToastHugsItsText() {
        hosting { _, container in
            let toast = ToastView.present("Copied", symbol: "doc.on.doc.fill", style: .confirmation, position: .bottom, in: container)
            settled(container)
            #expect(toast.bounds.width < container.layoutMarginsGuide.layoutFrame.width / 2)
        }
    }

    /// 48 pt with an action, 44 pt without, at the default text size.
    @Test func theHeightsAreCompact() {
        hosting { _, container in
            let plain = ToastView.present("Copied", symbol: nil, style: .confirmation, position: .top, in: container)
            let withUndo = undoable("Unfollowed @ava", in: container)
            let withRetry = ToastView.present(
                "Couldn't send", symbol: nil, style: .failure, action: .init("Retry") {}, position: .bottomLeading, in: container
            )
            settled(container)
            #expect(abs(plain.bounds.height - 44) < 0.5)
            #expect(abs(withUndo.bounds.height - 48) < 0.5)
            #expect(abs(withRetry.bounds.height - 48) < 0.5)
        }
    }

    /// One line of text, cut at its tail — never a second line.
    @Test func itIsOneLine() throws {
        try hosting { _, container in
            let toast = undoable(String(repeating: "A very long message ", count: 8), in: container)
            settled(container)
            let texts = labels(in: toast).filter { $0.text != "Undo" }
            let text = try #require(texts.first)
            #expect(texts.count == 1, "no second text line")
            #expect(text.numberOfLines == 1)
            #expect(text.lineBreakMode == .byTruncatingTail)
            #expect(abs(toast.bounds.height - 48) < 0.5, "a long message does not grow it")
        }
    }

    /// At accessibility text sizes, two lines, so the message is not cut to
    /// nothing.
    @Test func accessibilitySizesGetTwoLines() throws {
        try hosting { window, container in
            window.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
            window.layoutIfNeeded()
            let toast = undoable("Post deleted", in: container)
            settled(container)
            let text = try #require(labels(in: toast).first { $0.text == "Post deleted" })
            #expect(text.numberOfLines == 2)
        }
    }
}
