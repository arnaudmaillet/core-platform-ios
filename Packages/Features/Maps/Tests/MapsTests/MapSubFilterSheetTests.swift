import CoreModels
import Testing
import UIKit
@testable import Maps

/// The organize sheet's commit contract: edits live in the controller's own
/// buffer and reach the host ONLY through Done.
///
/// These drive the real controller (its view loaded, its diffable data source
/// applying) rather than the value model underneath — `MapSubFilterSections`
/// is already covered on its own, and what could actually regress here is the
/// wiring: an edit that publishes early, or a Cancel that publishes at all.
@MainActor
struct MapSubFilterSheetTests {
    private static func people(_ ids: [String]) -> [MapSubFilterOption] {
        MapSubFilterOption.people(ids.map {
            MapFavorite(profileID: ProfileID($0), title: $0.uppercased(), avatarURL: nil, handle: $0)
        })
    }

    private static func sub(_ id: String) -> MapSubFilter { .profile(ProfileID(id)) }

    /// Records every publish, so "how many times" is assertable and not just
    /// "what did it end up as".
    private final class Recorder {
        var published: [[MapSubFilter]] = []
        var last: [MapSubFilter]? { published.last }
    }

    /// A loaded sheet over the four-person catalogue, `a` and `b` in the bar.
    /// No image pipeline: avatars would be the one asynchronous thing here.
    private static func makeSheet(
        all: [String] = ["a", "b", "c", "d"],
        active: [String] = ["a", "b"]
    ) -> (MapSubFilterSheetViewController, Recorder) {
        let recorder = Recorder()
        let sheet = MapSubFilterSheetViewController(
            title: "Following",
            all: people(all),
            activeSubFilters: active.map(sub),
            imagePipeline: nil,
            rowActions: .none,
            onOptionsChanged: { recorder.published.append($0.map(\.subFilter)) }
        )
        sheet.loadViewIfNeeded()
        return (sheet, recorder)
    }

    // MARK: - Default edit mode

    @Test("The sheet opens already editing — there is no mode to switch into")
    func opensInEditMode() {
        let (sheet, _) = Self.makeSheet()
        #expect(sheet.isEditing)
    }

    @Test("Discard sits left, commit sits right, and nothing else is on the bar")
    func barCarriesCancelAndDone() {
        let (sheet, _) = Self.makeSheet()
        #expect(sheet.navigationItem.leftBarButtonItem === sheet.cancelItem)
        #expect(sheet.navigationItem.rightBarButtonItem === sheet.doneItem)
        #expect(sheet.navigationItem.leftBarButtonItems?.count == 1)
        #expect(sheet.navigationItem.rightBarButtonItems?.count == 1)
        // Spelled out, not system glyphs: iOS 26 draws `systemItem: .done` as
        // a bare ✓, which is precisely the mark this sheet must not show.
        #expect(sheet.cancelItem.title == "Cancel")
        #expect(sheet.doneItem.title == "Done")
    }

    // MARK: - Done availability

    @Test("An untouched sheet offers nothing to commit — Done starts dark")
    func doneStartsDisabled() {
        let (sheet, _) = Self.makeSheet()
        #expect(sheet.hasChanges == false)
        #expect(sheet.doneItem.isEnabled == false)
    }

    @Test("The first edit lights Done")
    func firstEditEnablesDone() {
        let (sheet, _) = Self.makeSheet()
        sheet.deactivate(Self.sub("a"))
        #expect(sheet.hasChanges)
        #expect(sheet.doneItem.isEnabled)
    }

    @Test("Promoting an Available row lights Done too")
    func promotingEnablesDone() {
        let (sheet, _) = Self.makeSheet()
        sheet.activate(Self.sub("c"))
        #expect(sheet.doneItem.isEnabled)
    }

    @Test("Undoing back to the opening arrangement darkens Done again")
    func revertingDisablesDone() {
        let (sheet, _) = Self.makeSheet()
        sheet.activate(Self.sub("c"))
        #expect(sheet.doneItem.isEnabled)
        sheet.deactivate(Self.sub("c"))
        // Back to exactly [a, b] — nothing left to tell the host.
        #expect(sheet.sections.active.map(\.subFilter) == ["a", "b"].map(Self.sub))
        #expect(sheet.hasChanges == false)
        #expect(sheet.doneItem.isEnabled == false)
    }

    @Test("A round trip that MOVES a row keeps Done lit — the order really did change")
    func removingAndReaddingReordersAndStaysEnabled() {
        let (sheet, _) = Self.makeSheet(all: ["a", "b", "c", "d"], active: ["a", "b", "c"])
        sheet.deactivate(Self.sub("a"))
        sheet.activate(Self.sub("a"))
        // `activate` appends, so `a` came back at the end, not at the front.
        #expect(sheet.sections.active.map(\.subFilter) == ["b", "c", "a"].map(Self.sub))
        #expect(sheet.doneItem.isEnabled)
    }

    @Test("A refused promotion is not an edit — Done stays dark")
    func refusedPromotionLeavesDoneDisabled() {
        let ids = ["a", "b", "c", "d", "e", "f", "g"]
        let full = Array(ids.prefix(MapSubFilterSections.defaultMaxActive))
        let (sheet, _) = Self.makeSheet(all: ids, active: full)
        #expect(sheet.activate(Self.sub("g")) == false)
        #expect(sheet.doneItem.isEnabled == false)
    }

    @Test("A stale active id doesn't count as an edit")
    func unknownOpeningIDsDoNotLightDone() {
        // The host can hand over an id the catalogue no longer carries (someone
        // unfollowed since). `MapSubFilterSections` drops it — the baseline has
        // to be measured AFTER that, or Done opens lit with nothing to commit.
        let recorder = Recorder()
        let sheet = MapSubFilterSheetViewController(
            title: "Following",
            all: Self.people(["a", "b"]),
            activeSubFilters: [Self.sub("a"), Self.sub("gone")],
            imagePipeline: nil,
            rowActions: .none,
            onOptionsChanged: { recorder.published.append($0.map(\.subFilter)) }
        )
        sheet.loadViewIfNeeded()
        #expect(sheet.doneItem.isEnabled == false)
    }

    // MARK: - Isolation

    @Test("Editing publishes nothing — the buffer is private until Done")
    func editsStayInTheBuffer() {
        let (sheet, recorder) = Self.makeSheet()
        sheet.deactivate(Self.sub("a"))
        sheet.activate(Self.sub("c"))
        sheet.activate(Self.sub("d"))
        sheet.deactivate(Self.sub("d"))
        #expect(recorder.published.isEmpty)
        // …while the buffer itself tracked every one of them.
        #expect(sheet.sections.active.map(\.subFilter) == [Self.sub("b"), Self.sub("c")])
    }

    // MARK: - Done

    @Test("Done publishes the edited arrangement, exactly once")
    func donePublishesTheBuffer() {
        let (sheet, recorder) = Self.makeSheet()
        sheet.deactivate(Self.sub("a"))
        sheet.activate(Self.sub("d"))
        sheet.commitAndDismiss()
        #expect(recorder.published.count == 1)
        #expect(recorder.last == [Self.sub("b"), Self.sub("d")])
    }

    @Test("Committing an untouched sheet publishes nothing")
    func doneWithoutEditsPublishesNothing() {
        // Unreachable through the disabled button, but `commitAndDismiss` is
        // the whole commit path: a no-op publish would still drag the host
        // through a restack and a preference write to land where it already is.
        let (sheet, recorder) = Self.makeSheet()
        sheet.commitAndDismiss()
        #expect(recorder.published.isEmpty)
    }

    @Test("Removing every row commits an empty list, not a no-op")
    func doneCanCommitAnEmptyRow() {
        let (sheet, recorder) = Self.makeSheet()
        sheet.deactivate(Self.sub("a"))
        sheet.deactivate(Self.sub("b"))
        sheet.commitAndDismiss()
        #expect(recorder.published.count == 1)
        #expect(recorder.last == [])
    }

    // MARK: - Cancel

    @Test("Cancel publishes nothing, however much was rearranged")
    func cancelDiscardsEverything() {
        let (sheet, recorder) = Self.makeSheet()
        sheet.deactivate(Self.sub("a"))
        sheet.deactivate(Self.sub("b"))
        sheet.activate(Self.sub("c"))
        sheet.cancelAndDismiss()
        #expect(recorder.published.isEmpty)
    }

    @Test("Cancel leaves the host's list untouched — the restore needs no undo")
    func cancelLeavesTheHostOnItsOriginalList() {
        // The host's copy only ever changes through a publish, so "restored"
        // and "never told" are the same state. This asserts that equivalence
        // the way the host experiences it.
        var hostList = ["a", "b"].map(Self.sub)
        let sheet = MapSubFilterSheetViewController(
            title: "Following",
            all: Self.people(["a", "b", "c", "d"]),
            activeSubFilters: hostList,
            imagePipeline: nil,
            rowActions: .none,
            onOptionsChanged: { hostList = $0.map(\.subFilter) }
        )
        sheet.loadViewIfNeeded()
        sheet.deactivate(Self.sub("a"))
        sheet.activate(Self.sub("d"))
        sheet.cancelAndDismiss()
        #expect(hostList == [Self.sub("a"), Self.sub("b")])
    }

    // MARK: - Capacity

    @Test("A full row refuses the promotion and the buffer is untouched")
    func capacityIsEnforcedInTheBuffer() {
        let ids = ["a", "b", "c", "d", "e", "f", "g"]
        let full = Array(ids.prefix(MapSubFilterSections.defaultMaxActive))
        let (sheet, recorder) = Self.makeSheet(all: ids, active: full)
        // `g` is the only one left in Available, and there is no seat for it.
        #expect(sheet.activate(Self.sub("g")) == false)
        #expect(sheet.sections.active.map(\.subFilter) == full.map(Self.sub))
        sheet.commitAndDismiss()
        #expect(recorder.published.isEmpty)
    }
}
