import Testing
import UIKit
@testable import DesignSystem

/// The toast's one-line layout (#1034): one line of text, a toast with an
/// action as wide as the margins allow with its control flush trailing, one
/// hugging its text; 48 pt, with an action or without (one height, 2026-11-06).
@MainActor
@Suite(.serialized, .ownsToastClock)
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
            undoable: ToastView.Undoable(commit: {}, undo: {}), in: container
        )
    }

    private func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels(in: $0) }
    }

    private func settled(_ container: UIView) {
        container.setNeedsLayout()
        container.layoutIfNeeded()
    }

    /// With an action too, the capsule hugs its content (#2143, the owner's
    /// device check) — and Undo sits at its trailing edge, not mid-capsule.
    @Test func anUndoToastHugsItsContentWithItsControlTrailing() throws {
        try hosting { _, container in
            let toast = undoable("Post deleted", in: container)
            settled(container)
            let margins = container.layoutMarginsGuide.layoutFrame.width
            #expect(toast.bounds.width < margins - 60, "an action toast spans the screen: \(toast.bounds.width) of \(margins)")
            let control = try #require(toast.undoButton)
            let trailing = toast.bounds.maxX - control.convert(control.bounds, to: toast).maxX
            #expect(trailing <= Spacing.sm + 1, "\(trailing) pt after the control")
        }
    }

    /// A long message meets the margins and truncates; the action stays
    /// whole, at the trailing edge.
    @Test func aLongActionToastStopsAtTheMarginsWithItsControlWhole() throws {
        try hosting { _, container in
            let toast = undoable(String(repeating: "A very long message ", count: 8), in: container)
            settled(container)
            let margins = container.layoutMarginsGuide.layoutFrame.width
            #expect(abs(toast.bounds.width - min(margins, ToastView.Metrics.maximumWidth)) < 1)
            let control = try #require(toast.undoButton)
            #expect(control.bounds.width >= control.intrinsicContentSize.width - 0.5, "Undo was squeezed")
        }
    }

    /// The action is a filled capsule inside the toast's, concentric — as far
    /// from the toast's trailing edge as from its top — and takes touches
    /// up to 44 pt around it.
    @Test func theActionIsAFilledConcentricCapsuleWithAFullTarget() throws {
        try hosting { _, container in
            let toast = ToastView.present(
                "Couldn't send", symbol: nil, style: .failure, action: .init("Retry") {}, in: container
            )
            settled(container)
            let action = try #require(toast.actionButton as? ToastActionButton)
            #expect(action.configuration?.baseBackgroundColor == ToastActionButton.ground)
            let frame = action.convert(action.bounds, to: toast)
            let trailing = toast.bounds.maxX - frame.maxX
            let top = frame.minY - toast.bounds.minY
            #expect(abs(trailing - top) <= 1.5, "not concentric: \(trailing) pt trailing, \(top) pt on top")
            #expect(action.bounds.height < ToastActionButton.touchTarget)
            #expect(action.point(inside: CGPoint(x: action.bounds.midX, y: -4), with: nil), "the target is the capsule only")
        }
    }

    /// Without one, the capsule hugs its text.
    @Test func aPlainToastHugsItsText() {
        hosting { _, container in
            let toast = ToastView.present("Copied", symbol: "doc.on.doc.fill", style: .confirmation, in: container)
            settled(container)
            #expect(toast.bounds.width < container.layoutMarginsGuide.layoutFrame.width / 2)
        }
    }

    /// 48 pt, with an action or without, at the default text size: the
    /// disc and the action capsule concentric with the toast (2026-11-06).
    @Test func theHeightsAreCompact() {
        // Each measured at rest before the next replaces it (one result
        // toast at a time, #2143).
        hosting { _, container in
            let plain = ToastView.present("Copied", symbol: nil, style: .confirmation, in: container)
            settled(container)
            #expect(abs(plain.bounds.height - 48) < 0.5)
            let withUndo = undoable("Unfollowed @ava", in: container)
            settled(container)
            #expect(abs(withUndo.bounds.height - 48) < 0.5)
            let withRetry = ToastView.present(
                "Couldn't send", symbol: nil, style: .failure, action: .init("Retry") {}, in: container
            )
            settled(container)
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

    /// At accessibility text sizes too, one line: it truncates, never wraps
    /// (#2143) — the whole message is a tap away (#1449).
    @Test func accessibilitySizesStayOneLine() throws {
        try hosting { window, container in
            window.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
            window.layoutIfNeeded()
            let toast = undoable("Post deleted", in: container)
            settled(container)
            let text = try #require(labels(in: toast).first { $0.text == "Post deleted" })
            #expect(text.numberOfLines == 1)
        }
    }
}
