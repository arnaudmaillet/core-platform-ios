import Testing
import UIKit
@testable import DesignSystem

/// The day chip's band (#2238): 8 pt above the chip and 12 pt under it, down
/// to its day's first row. Under it was 4 pt, and the chip read as glued to
/// the message below it (the owner, 2026-11-10).
@MainActor
struct DayPillHeaderGapTests {
    private func laidOut(_ configure: (DayPillHeaderView) -> Void = { _ in }) -> DayPillHeaderView {
        let header = DayPillHeaderView()
        header.configure(title: "Yesterday")
        configure(header)
        let size = header.systemLayoutSizeFitting(
            CGSize(width: 390, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        header.frame = CGRect(origin: .zero, size: size)
        header.layoutIfNeeded()
        return header
    }

    @Test func theChipHasMoreRoomUnderItThanAboveIt() {
        let header = laidOut()
        let chip = header.debugChipFrame
        #expect(abs(chip.minY - DayPillHeaderView.topGap) < 0.5, "chip \(chip) in \(header.bounds)")
        #expect(abs(header.bounds.height - chip.maxY - DayPillHeaderView.bottomGap) < 0.5, "chip \(chip) in \(header.bounds)")
        #expect(DayPillHeaderView.bottomGap >= DayPillHeaderView.topGap, "under the chip at least the space above it")
        #expect(DayPillHeaderView.bottomGap == Spacing.md)
    }

    @Test func aHostSetsItsOwnGap() {
        let header = laidOut { $0.gapBelow = Spacing.lg }
        #expect(abs(header.bounds.height - header.debugChipFrame.maxY - Spacing.lg) < 0.5,
                "chip \(header.debugChipFrame) in \(header.bounds)")
        #expect(header.gapBelow == Spacing.lg)
    }
}
