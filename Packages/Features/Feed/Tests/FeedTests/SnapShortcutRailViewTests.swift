import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The shortcut wheel's geometry contract: a full-height rail whose resting
/// window shows exactly three bubbles docked at the bottom, with the rest
/// scroll-discoverable, detent-snapped releases, and a per-post deterministic
/// placeholder payload (the flight-replica identity requirement).
@MainActor
struct SnapShortcutRailViewTests {
    /// A rail frame comfortably taller than the resting window, as on device
    /// (ticker top → nav bar bottom).
    private static let railHeight: CGFloat = 520

    private func makeRail(symbolCount: Int = 9) -> SnapShortcutRailView {
        let rail = SnapShortcutRailView(
            frame: CGRect(x: 0, y: 0, width: SnapShortcutRailView.railWidth, height: Self.railHeight)
        )
        rail.setSymbols(Array(SnapShortcutRailView.symbolPool.prefix(symbolCount)))
        rail.layoutIfNeeded()
        return rail
    }

    @Test func restingWindowShowsExactlyThreeIcons() {
        let rail = makeRail()
        // The top inset pads the scroll range down to the resting window…
        #expect(rail.contentInset.top == Self.railHeight - SnapShortcutRailView.restingWindowHeight)
        // …and the rail rests parked against it.
        #expect(rail.contentOffset.y == -rail.contentInset.top)
        #expect(rail.visibleIconCount == SnapShortcutRailView.restingIconCount)
    }

    @Test func scrollingUpRevealsTheFullColumn() {
        let rail = makeRail()
        let maxOffset = rail.contentSize.height - rail.bounds.height
        // Nine bubbles fit inside the 520pt rail, so the top clamp reveals
        // them all, bottom-aligned to the rail's frame.
        rail.contentOffset = CGPoint(x: 0, y: maxOffset)
        #expect(rail.visibleIconCount == 9)
    }

    @Test func emptyPayloadHidesTheRail() {
        let rail = makeRail()
        #expect(rail.isHidden == false)
        rail.reset()
        #expect(rail.isHidden == true)
        #expect(rail.visibleIconCount == 0)
    }

    @Test func releasesSnapToTheStepGrid() {
        let step = SnapShortcutRailView.step
        let rest: CGFloat = -388 // arbitrary rest offset
        let max: CGFloat = -100

        // Mid-flick proposals round to the nearest detent.
        #expect(SnapShortcutRailView.snappedTarget(
            proposed: rest + 1.4 * step, restOffset: rest, step: step, maxOffset: max
        ) == rest + step)
        #expect(SnapShortcutRailView.snappedTarget(
            proposed: rest + 1.6 * step, restOffset: rest, step: step, maxOffset: max
        ) == rest + 2 * step)
        // Undershoot clamps to rest; overshoot clamps to the (off-grid)
        // bottom-aligned column.
        #expect(SnapShortcutRailView.snappedTarget(
            proposed: rest - step, restOffset: rest, step: step, maxOffset: max
        ) == rest)
        #expect(SnapShortcutRailView.snappedTarget(
            proposed: 0, restOffset: rest, step: step, maxOffset: max
        ) == max)
        // A payload too small to scroll (maxOffset below rest) pins to rest.
        #expect(SnapShortcutRailView.snappedTarget(
            proposed: 0, restOffset: rest, step: step, maxOffset: rest - 40
        ) == rest)
    }

    @Test func placeholderPayloadIsDeterministicPerPost() {
        let id = PostID("0198c5f2-1111-7000-8000-000000000001")
        // Same post → same wheel (the live cell and its flight replica must
        // never disagree).
        #expect(SnapShortcutRailView.placeholderPayload(for: id)
            == SnapShortcutRailView.placeholderPayload(for: id))
        // Full pool, no duplicates — it's a shuffle, not a sample.
        let payload = SnapShortcutRailView.placeholderPayload(for: id)
        #expect(Set(payload).count == SnapShortcutRailView.symbolPool.count)
    }

    /// The chrome-level contract this feature is really about: the rail owns
    /// the trailing column (ticker top → nav bar) and the subtitle zone's
    /// slot stops short of it instead of running the full width.
    @Test func chromeReservesTheTrailingColumnForTheRail() throws {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-1"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "caption",
            mediaURL: URL(string: "mock://media/1"),
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        chrome.layoutIfNeeded()

        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        let subtitle = try #require(chrome.subviews.compactMap { $0 as? SnapSubtitleView }.first)
        let ticker = try #require(chrome.subviews.compactMap { $0 as? SnapCommentTickerView }.first)

        // Trailing column: one bubble wide, Spacing.md off the margin
        // (no window → zero safe area → margins guide == bounds).
        #expect(rail.frame.width == SnapShortcutRailView.railWidth)
        #expect(rail.frame.maxX == 390 - Spacing.md)
        // Vertical span: under the nav bar down to the ticker's top edge.
        #expect(rail.frame.minY == Spacing.sm)
        #expect(rail.frame.maxY == ticker.frame.minY - Spacing.sm)
        // The subtitle zone stops short of the rail — the width reduction.
        #expect(subtitle.frame.maxX == rail.frame.minX - Spacing.md)
        // A media post shows its wheel.
        #expect(rail.isHidden == false)
    }

    @Test func textOnlyPostsKeepTheEmptyShell() throws {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-2"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "text-only thought",
            mediaURL: nil,
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        #expect(rail.isHidden == true)
    }
}
