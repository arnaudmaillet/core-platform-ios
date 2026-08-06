import CoreModels
import Foundation
import Testing
import UIKit
@testable import Chat

/// Where the row's two management marks sit.
///
/// They used to be at opposite ends: mute inline after the title, pin under the
/// timestamp — so a muted-and-pinned row said so twice, in two places, and
/// neither read as a group. Both are in the trailing column now, ordered
/// `[mute][pin]` toward the edge.
///
/// Asserted on FRAMES rather than on the view tree, because the arrangement is
/// the behaviour: a stack that holds both in the right order but lays them out
/// somewhere unexpected is exactly the failure a reader of the code would miss.
@MainActor
@Suite("Conversation cell glyph layout")
struct ConversationCellLayoutTests {
    private func makeCell(muted: Bool, pinned: Bool) -> ConversationCell {
        let model = ConversationDisplayModel(
            conversation: Conversation(
                id: ConversationID("c1"),
                title: "Ava Moreau",
                lastMessage: "hi",
                lastActivityAt: Date(timeIntervalSince1970: 0),
                otherMemberIDs: [ProfileID("peer-1")],
                lastMessageIsMine: false,
                lastMessageID: "c1-latest",
                isUnread: false,
                unreadCount: 0
            ),
            now: Date(timeIntervalSince1970: 60),
            isPinned: pinned,
            isMuted: muted,
            isUnread: false,
            unreadCount: 0
        )
        let cell = ConversationCell(style: .default, reuseIdentifier: nil)
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: 76)
        cell.configure(with: model)
        cell.layoutIfNeeded()
        return cell
    }

    /// Every visible image view in the cell, with its frame in cell space.
    private func glyphs(in cell: ConversationCell) -> [(view: UIImageView, frame: CGRect)] {
        var found: [(UIImageView, CGRect)] = []
        func walk(_ view: UIView) {
            if let image = view as? UIImageView, !image.isHidden, image.image != nil,
               image.bounds.width > 0 {
                found.append((image, image.convert(image.bounds, to: cell)))
            }
            view.subviews.forEach(walk)
        }
        walk(cell.contentView)
        return found
    }

    @Test("Mute sits to the left of pin")
    func muteIsLeftOfPin() {
        let cell = makeCell(muted: true, pinned: true)
        let marks = glyphs(in: cell).sorted { $0.frame.minX < $1.frame.minX }

        #expect(marks.count == 2)
        let mute = try? #require(marks.first)
        let pin = try? #require(marks.last)
        // Ordered toward the trailing edge, and not overlapping.
        #expect((mute?.frame.maxX ?? 0) <= (pin?.frame.minX ?? 0))
    }

    /// Both are in the TRAILING column — the failure this replaced had mute in
    /// the title row, which is on the leading half of the cell.
    @Test("Both marks sit in the trailing half of the row")
    func bothMarksAreTrailing() {
        let cell = makeCell(muted: true, pinned: true)
        let marks = glyphs(in: cell)

        #expect(marks.count == 2)
        #expect(marks.allSatisfy { $0.frame.minX > cell.bounds.midX })
    }

    @Test("They share a baseline — same vertical centre")
    func marksAreVerticallyAligned() {
        let cell = makeCell(muted: true, pinned: true)
        let centres = glyphs(in: cell).map { $0.frame.midY }

        #expect(centres.count == 2)
        #expect(abs((centres.first ?? 0) - (centres.last ?? 0)) < 0.5)
    }

    @Test("An unmuted, unpinned row shows neither")
    func plainRowShowsNoMarks() {
        #expect(glyphs(in: makeCell(muted: false, pinned: false)).isEmpty)
    }

    @Test("Muted only shows one mark")
    func mutedOnlyShowsOne() {
        #expect(glyphs(in: makeCell(muted: true, pinned: false)).count == 1)
    }

    /// The pinned band is applied by `configure`, not deferred.
    ///
    /// It used to arrive only when the row was re-rendered after its move
    /// animation settled, so pinning greyed the row a beat late — on the one
    /// action whose entire feedback IS that tint. The list now repaints the
    /// row in place before the snapshot that moves it, and this pins the half
    /// the cell owns: configure with `isPinned` and the band is there.
    @Test("Pinning tints the row as soon as it is configured")
    func pinnedRowIsTintedOnConfigure() {
        #expect(makeCell(muted: false, pinned: true).backgroundView?.backgroundColor == .quaternarySystemFill)
    }

    @Test("An unpinned row carries no band")
    func unpinnedRowHasNoTint() {
        #expect(makeCell(muted: false, pinned: false).backgroundView?.backgroundColor == nil)
    }

    /// Reconfiguring the same cell from pinned to unpinned clears the band —
    /// the cross-fade path must not leave the colour behind.
    @Test("Unpinning clears the band")
    func unpinningClearsTheTint() {
        let cell = makeCell(muted: false, pinned: true)
        let unpinned = ConversationDisplayModel(
            conversation: Conversation(
                id: ConversationID("c1"), title: "Ava Moreau", lastMessage: "hi",
                lastActivityAt: Date(timeIntervalSince1970: 0),
                otherMemberIDs: [ProfileID("peer-1")], lastMessageIsMine: false,
                lastMessageID: "c1-latest", isUnread: false, unreadCount: 0
            ),
            now: Date(timeIntervalSince1970: 60),
            isPinned: false, isMuted: false, isUnread: false, unreadCount: 0
        )
        cell.configure(with: unpinned)

        #expect(cell.backgroundView?.backgroundColor == nil)
    }
}
