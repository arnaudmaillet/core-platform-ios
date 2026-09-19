import Testing
import UIKit
@testable import Upload

/// The camera's toolbar rule, `[selector] ---- [close]`, where a test can ask
/// about it: the widths, and how the bar is read.
@MainActor
struct CaptureBarLayoutTests {
    private static let selectorWants: CGFloat = 150
    private static let closeWants: CGFloat = 36
    private static let bubble: CGFloat = 36

    private func widths(available: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        EditorSelectorLayout.leadingCapped(
            leadingWants: Self.selectorWants, trailingWants: Self.closeWants,
            available: available, leadingFloor: Self.bubble
        )
    }

    /// ⚠️ With room, the selector takes its OWN width — not the rest — and
    /// the close button its own; the difference is left to the bar.
    @Test func withRoomTheSelectorTakesItsOwnWidthNotTheRest() {
        let held = widths(available: 306)
        #expect(held.leading == Self.selectorWants)
        #expect(held.trailing == Self.closeWants)
        #expect(306 - held.leading - held.trailing == 120, "the slack is not handed to anyone")
    }

    /// ⚠️ Without, it takes what the close button leaves; never less than
    /// one bubble; the close button keeps its width while one bubble fits.
    @Test func withoutRoomTheSelectorIsCappedAtWhatIsLeft() {
        let tight = widths(available: 154)
        #expect(tight.leading == 118)
        #expect(tight.trailing == Self.closeWants)
        let tighter = widths(available: 60)
        #expect(tighter.leading == Self.bubble, "one bubble at least")
        #expect(tighter.leading + tighter.trailing <= 60, "never more than the bar has")
        #expect(widths(available: 0) == (0, 0))
        #expect(widths(available: .infinity) == (0, 0))
    }

    /// ⚠️ The editor's rule is not this one: its trailing selector still
    /// takes the rest.
    @Test func theEditorsRuleStillGivesTheRestAway() {
        let editor = EditorSelectorLayout.widths(leadingWants: 36, available: 306, trailingFloor: 36)
        #expect(editor == (36, 270))
    }

    /// ⚠️ Read with slack in the flexible space, the bar's gap is KEPT — the
    /// slack does not pass for gap — while margin and platter are measured.
    /// Read flush, the gap is what stands between the two platters.
    @Test func theGapIsReadOnlyWhileTheFlexibleSpaceHoldsNothing() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        defer { window.isHidden = true }
        func strip(platterX: CGFloat, width: CGFloat) -> UIView {
            let platter = UIView(frame: CGRect(x: platterX, y: 800, width: width + 12, height: 48))
            let view = UIView(frame: CGRect(x: 6, y: 6, width: width, height: 36))
            platter.addSubview(view)
            window.addSubview(platter)
            return view
        }
        // Platters: 30…192 and 300…348 — 108 between them, 88 of it slack.
        let selector = strip(platterX: 30, width: 150)
        let close = strip(platterX: 300, width: 36)

        let kept = try #require(BottomBarShare.measure(leading: selector, trailing: close, flush: false, keepingGap: 20))
        #expect(kept == ToolbarGeometry(margin: 30, platter: 12, gap: 20), "the gap kept: \(kept)")

        close.superview?.frame.origin.x = 222
        let flush = try #require(BottomBarShare.measure(leading: selector, trailing: close, flush: true, keepingGap: 20))
        #expect(flush.gap == 30, "flush, the gap is read: \(flush)")
    }
}
