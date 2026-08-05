import CoreStorage
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile

/// Which tabs a profile shows, and where the two new ones get their contents.
///
/// Saved and Liked are the viewer's own, in the strict sense that nothing on
/// the wire could hand either of them to anybody else: there is no save
/// contract at all, and reactions can be written and counted but never listed.
/// So the gating is not a policy choice to be revisited — it is the only shape
/// the data allows, and these pin it.
@MainActor
struct ProfileTabsTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    // MARK: - Who sees what

    @Test func yourOwnProfileCarriesSavedAndLiked() {
        #expect(ProfileTab.ownTabs.contains(.saved))
        #expect(ProfileTab.ownTabs.contains(.reactions))
        #expect(ProfileTab.ownTabs.count == 5)
    }

    /// ⚠️ And nobody else's does. A saved pile has no owner but the device it
    /// is on; showing one on a profile reached by tapping a handle would be
    /// showing the viewer their own pile under someone else's name.
    @Test func someoneElsesProfileCarriesNeither() {
        #expect(ProfileTab.publicTabs.contains(.saved) == false)
        #expect(ProfileTab.publicTabs.contains(.reactions) == false)
        #expect(ProfileTab.publicTabs.count == 3)
    }

    /// The public three come first and in their existing order, so the tabs a
    /// viewer already knows do not move when two more appear beside them.
    @Test func theExistingTabsKeepTheirPlaces() {
        #expect(Array(ProfileTab.ownTabs.prefix(3)) == ProfileTab.publicTabs)
    }

    // MARK: - Which axis they are on

    /// ⚠️ Saved and Liked are CORPORA, not formats. The source filter — All /
    /// Posts / Reposts / Tagged — asks what this profile published, and there
    /// is no answer to any of it about a post somebody else wrote. Reporting no
    /// format is what keeps the tray and the stored preference away from them.
    @Test func theCorpusTabsHaveNoFormat() {
        #expect(ProfileTab.saved.format == nil)
        #expect(ProfileTab.reactions.format == nil)
    }

    @Test func theFormatTabsReportTheirFormat() {
        #expect(ProfileTab.format(.activity).format == .activity)
        #expect(ProfileTab.format(.media).format == .media)
        #expect(ProfileTab.format(.short).format == .short)
    }

    /// Every tab is titled, and titled distinctly — five segments sharing one
    /// capsule with a repeat among them would be unreadable.
    @Test func everyTabHasItsOwnTitle() {
        let titles = ProfileTab.ownTabs.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    // MARK: - The pager follows the tab list

    private func pager(_ tabs: [ProfileTab]) -> ProfileGalleryPagerView {
        let pager = ProfileGalleryPagerView(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), tabs: tabs
        )
        pager.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        pager.layoutIfNeeded()
        return pager
    }

    /// ⚠️ Five tabs means five PAGES, each with its own scroll position — the
    /// page count used to be a constant, and a selector with more segments than
    /// the pager has pages indexes past the end on the last tab.
    @Test func thePagerBuildsOnePageForEachTab() {
        #expect(pager(ProfileTab.ownTabs).debugVerticalOffsets.count == 5)
        #expect(pager(ProfileTab.publicTabs).debugVerticalOffsets.count == 3)
    }

    /// And the new pages join the same coordinator as the old: each keeps its
    /// own place, which is the property the whole architecture turns on.
    @Test func theNewPagesKeepTheirOwnScrollPositions() {
        let pager = pager(ProfileTab.ownTabs)
        pager.setMinimumScrollTravel(2_000)
        pager.setSharedTravel(dockLine: 300, contentFloor: 360)
        pager.debugSetOffset(900, forPage: 4)
        pager.debugSetOffset(400, forPage: 0)
        #expect(pager.debugAlignedOffset(forPage: 4) == 900)
    }

    /// A swipe onto the last tab reports THAT tab — an off-by-one here lands
    /// the selector on Saved while the pager shows Liked.
    @Test func settlingOnTheLastTabReportsIt() {
        let pager = pager(ProfileTab.ownTabs)
        var settled: [ProfileTab] = []
        pager.onPageSettled = { settled.append($0) }
        pager.scrub(to: 4)
        pager.settleAfterScrub(velocityInPages: 0)
        #expect(settled == [.reactions])
    }
}

/// The saved pile itself.
///
/// Client-owned, because no service carries one. That makes this store the only
/// source of truth there is for the Saved tab, which is a good reason for its
/// ordering and its persistence to be asserted rather than assumed.
struct PostBookmarkStoreTests {
    private func store() -> PostBookmarkStore {
        let defaults = UserDefaults(suiteName: "bookmark-tests-\(UUID().uuidString)")!
        return PostBookmarkStore(defaults: defaults)
    }

    @Test func aFreshPileIsEmpty() {
        #expect(store().savedPostIDs.isEmpty)
    }

    @Test func savingAndUnsavingAreTheSameTap() {
        let store = store()
        #expect(store.toggle("post-1") == true)
        #expect(store.isSaved("post-1"))
        #expect(store.toggle("post-1") == false)
        #expect(store.isSaved("post-1") == false)
        #expect(store.savedPostIDs.isEmpty)
    }

    /// ⚠️ Newest first. A saved pile is read as a pile, not as a set: the thing
    /// you saved a minute ago is the thing you came back for, and appending
    /// would bury it under everything older.
    @Test func theMostRecentlySavedComesFirst() {
        let store = store()
        store.toggle("post-1")
        store.toggle("post-2")
        store.toggle("post-3")
        #expect(store.savedPostIDs == ["post-3", "post-2", "post-1"])
    }

    /// Re-saving something moves it back to the front rather than duplicating
    /// it — the pile is ordered, but it is still a set.
    @Test func savingSomethingTwiceDoesNotDuplicateIt() {
        let store = store()
        store.toggle("post-1")
        store.toggle("post-2")
        store.toggle("post-1")  // unsaves
        store.toggle("post-1")  // saves again
        #expect(store.savedPostIDs == ["post-1", "post-2"])
    }

    /// ⚠️ It outlives the object. This is the whole difference from the session
    /// `Set` it replaced: two surfaces read this list, and one of them is a
    /// screen the other has never met.
    @Test func thePileOutlivesTheStoreThatWroteIt() {
        let defaults = UserDefaults(suiteName: "bookmark-persist-\(UUID().uuidString)")!
        PostBookmarkStore(defaults: defaults).toggle("post-7")
        #expect(PostBookmarkStore(defaults: defaults).savedPostIDs == ["post-7"])
    }

    /// Changes announce themselves, so the Saved tab reloads rather than polls.
    @Test func aChangeIsAnnounced() {
        let store = store()
        var changes = 0
        store.onChange = { changes += 1 }
        store.toggle("post-1")
        store.toggle("post-1")
        #expect(changes == 2)
    }
}
