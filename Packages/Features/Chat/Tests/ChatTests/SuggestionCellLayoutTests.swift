import CoreModels
import DesignSystem
import Foundation
import Testing
import UIKit
@testable import Chat

/// The Suggestions row keeps the @handle readable (#915).
///
/// It used to share one line with the reason, and the handle was the only part
/// allowed to shrink: "2 mutual connections" took the room and every row read
/// "@…  • 2 mutual connections".
///
/// Asserted on FRAMES at the two phone widths that matter, with the longest
/// handle and the longest reason the mock produces — the failure was a layout
/// one, and a view tree holding the right text would not have shown it.
@MainActor
@Suite("Suggestion cell layout")
struct SuggestionCellLayoutTests {
    /// The longest handle in the mock dataset.
    private static let longHandle = "chloe.baptiste"
    /// The longest reason the mock produces is a mutual count; two digits so
    /// the test has margin over the seeded graph's.
    private static let longReason = SuggestedAccount.Reason.followedBy(names: [], total: 12)

    private func layOut(
        width: CGFloat, handle: String, reason: SuggestedAccount.Reason, following: Bool = false
    ) -> SuggestionCell {
        let cell = SuggestionCell(style: .default, reuseIdentifier: nil)
        cell.configure(
            with: SuggestionDisplayModel(
                account: SuggestedAccount(
                    id: ProfileID("s1"), handle: handle, displayName: "Chloé Baptiste",
                    avatarURL: nil, reason: reason
                ),
                isFollowing: following
            ),
            imagePipeline: nil
        )
        let height = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        cell.frame = CGRect(x: 0, y: 0, width: width, height: height)
        cell.layoutIfNeeded()
        return cell
    }

    private func frame(of view: UIView, in cell: UITableViewCell) -> CGRect {
        view.convert(view.bounds, to: cell)
    }

    /// How wide `text` draws in the label's font, less half a point: a label
    /// sized to its text lands on the pixel grid, a hair under the raw width.
    private func drawnWidth(of text: String, in label: UILabel) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: label.font as Any]).width - 0.5
    }

    /// The handle shows at least "@" and six characters — on develop it was
    /// squeezed to the width of "@…".
    @Test("The handle stays readable beside the longest reason", arguments: [375.0, 402.0] as [CGFloat])
    func handleIsNotCollapsed(width: CGFloat) {
        for following in [false, true] {
            let cell = layOut(width: width, handle: Self.longHandle, reason: Self.longReason, following: following)
            let handle = cell.debugHandleLabel
            let readable = drawnWidth(of: "@" + Self.longHandle.prefix(6) + "…", in: handle)
            #expect(
                handle.bounds.width >= readable,
                "@\(width) following=\(following): the handle is \(handle.bounds.width) pt, needs \(readable) for \"@\(Self.longHandle.prefix(6))…\""
            )
        }
    }

    /// The reason has a line of its own under the handle, and neither runs
    /// under the buttons. Beside Follow — how every suggestion arrives — it
    /// is all there; beside the wider Following, at 375, it may lose its
    /// last letters, at its tail.
    @Test("The reason has its own line, clear of the buttons", arguments: [375.0, 402.0] as [CGFloat])
    func reasonHasItsOwnLineClearOfTheButtons(width: CGFloat) {
        for following in [false, true] {
            let cell = layOut(width: width, handle: Self.longHandle, reason: Self.longReason, following: following)
            let reason = cell.debugReasonLabel
            let handle = cell.debugHandleLabel
            let buttonsStart = frame(of: cell.debugFollowButton, in: cell).minX
            #expect(reason.text == "12 mutual connections")
            #expect(reason.lineBreakMode == .byTruncatingTail)
            if !following {
                #expect(
                    reason.bounds.width >= drawnWidth(of: reason.text ?? "", in: reason),
                    "@\(width): the reason is cut to \(reason.bounds.width) pt"
                )
            }
            #expect(frame(of: reason, in: cell).minY >= frame(of: handle, in: cell).maxY, "the reason is not under the handle")
            #expect(frame(of: reason, in: cell).maxX <= buttonsStart)
            #expect(frame(of: handle, in: cell).maxX <= buttonsStart)
        }
    }

    /// Follow and ✕ sit exactly where they sit on a row with a short handle
    /// and no reason, at their own size — the text column gives way, never
    /// the buttons.
    @Test("Follow and ✕ keep their size and position", arguments: [375.0, 402.0] as [CGFloat])
    func buttonsKeepTheirSizeAndPosition(width: CGFloat) {
        for following in [false, true] {
            let long = layOut(width: width, handle: Self.longHandle, reason: Self.longReason, following: following)
            let short = layOut(width: width, handle: "ava", reason: .followsYou, following: following)
            let follow = frame(of: long.debugFollowButton, in: long)
            let dismiss = frame(of: long.debugDismissButton, in: long)
            // Layout lands on the pixel grid; anything past a hundredth of a
            // point is a real move.
            func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
            #expect(same(follow.width, long.debugFollowButton.intrinsicContentSize.width), "Follow was squeezed")
            #expect(same(dismiss.width, long.debugDismissButton.intrinsicContentSize.width), "the ✕ was squeezed")
            #expect(same(dismiss.maxX, width - Spacing.lg), "the ✕ left the trailing margin")
            #expect(same(follow.minX, frame(of: short.debugFollowButton, in: short).minX))
            #expect(same(follow.width, frame(of: short.debugFollowButton, in: short).width))
            #expect(same(dismiss.minX, frame(of: short.debugDismissButton, in: short).minX))
            // Centred on the row like the disc, whatever the row's height.
            #expect(abs(follow.midY - long.bounds.midY) <= 0.5)
            #expect(abs(dismiss.midY - long.bounds.midY) <= 0.5)
        }
    }
}
