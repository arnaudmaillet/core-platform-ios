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

    /// Posts | Saved | Liked — the owner's call for #631 (2026-10-07).
    @Test func yourOwnProfileCarriesSavedAndLiked() {
        #expect(ProfileTab.ownTabs == [.format(.activity), .saved, .reactions])
        #expect(ProfileTab.ownTabs.map(\.title) == ["Posts", "Saved", "Liked"])
    }

    /// ⚠️ And nobody else's does. A saved pile has no owner but the device it
    /// is on; showing one on a profile reached by tapping a handle would be
    /// showing the viewer their own pile under someone else's name.
    @Test func someoneElsesProfileCarriesNeither() {
        #expect(ProfileTab.publicTabs.contains(.saved) == false)
        #expect(ProfileTab.publicTabs.contains(.reactions) == false)
    }

    /// ⚠️ THREE PAGES (#696): anyone else's profile is Posts · Reposts ·
    /// Tagged, each its own list, where it was one list and a top filter.
    @Test func someoneElsesProfileIsPostsRepostsTagged() {
        #expect(ProfileTab.publicTabs == [.format(.activity), .reposts, .tagged])
        #expect(ProfileTab.publicTabs.map(\.title) == ["Posts", "Reposts", "Tagged"])
    }

    /// Posts comes first on both, so a profile opens on the list a viewer
    /// knows from every other one.
    @Test func postsComesFirstOnBoth() {
        #expect(ProfileTab.ownTabs.first == .format(.activity))
        #expect(ProfileTab.publicTabs.first == .format(.activity))
    }

    /// Reposts and Tagged load more as they scroll, like Posts; Saved and
    /// Liked arrive whole.
    @Test func thePublishedPagesPage() {
        #expect(ProfileTab.publicTabs.allSatisfy { $0.pages })
        #expect(!ProfileTab.saved.pages && !ProfileTab.reactions.pages)
        #expect(ProfileTab.reposts.format == nil && ProfileTab.tagged.format == nil)
    }

    /// Posts is For You's Discover list; Saved and Liked stay timelines; the
    /// media mosaic is the gallery "View all" pushes.
    @Test func eachPageTakesItsShape() {
        #expect(ProfileGalleryPagerView.style(for: .format(.activity)) == .discover)
        #expect(ProfileGalleryPagerView.style(for: .saved) == .list)
        #expect(ProfileGalleryPagerView.style(for: .reactions) == .list)
        #expect(ProfileGalleryPagerView.style(for: .format(.media)) == .grid)
        // Someone else's Reposts and Tagged are For You lists too (#696).
        #expect(ProfileGalleryPagerView.style(for: .reposts) == .discover)
        #expect(ProfileGalleryPagerView.style(for: .tagged) == .discover)
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

    /// ⚠️ One PAGE per tab, each with its own scroll position — the page
    /// count used to be a constant, and a selector with more segments than
    /// the pager has pages indexes past the end on the last tab.
    @Test func thePagerBuildsOnePageForEachTab() {
        #expect(pager(ProfileTab.ownTabs).debugVerticalOffsets.count == 3)
        #expect(pager(ProfileTab.publicTabs).debugVerticalOffsets.count == 3)
    }

    /// And the new pages join the same coordinator as the old: each keeps its
    /// own place, which is the property the whole architecture turns on.
    @Test func theNewPagesKeepTheirOwnScrollPositions() {
        let pager = pager(ProfileTab.ownTabs)
        pager.setMinimumScrollTravel(2_000)
        pager.setSharedTravel(dockLine: 300, contentFloor: 360)
        pager.debugSetOffset(900, forPage: 2)
        pager.debugSetOffset(400, forPage: 0)
        #expect(pager.debugAlignedOffset(forPage: 2) == 900)
    }

    /// A swipe onto the last tab reports THAT tab — an off-by-one here lands
    /// the selector on Saved while the pager shows Liked.
    ///
    /// Driven through the scroll view's own settle, which is the only way a
    /// swipe commits now that the capsule carries no gesture of its own.
    @Test func settlingOnTheLastTabReportsIt() {
        let pager = pager(ProfileTab.ownTabs)
        var settled: [ProfileTab] = []
        pager.onPageSettled = { settled.append($0) }
        pager.debugScrollView.contentOffset = CGPoint(x: 2 * pager.bounds.width, y: 0)
        pager.scrollViewDidEndDecelerating(pager.debugScrollView)
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

/// What each tab says when it has nothing.
///
/// A blank grid reads as a screen that failed. The difference between that and
/// "there is genuinely nothing here" is the entire reason the shared empty
/// state exists — and on a five-tab profile it also has to say WHICH nothing,
/// because an empty Gallery and an empty Saved pile look identical and mean
/// completely different things.
@MainActor
struct ProfileEmptyStateTests {
    @Test func everyTabSaysWhichNothingItIs() {
        let states = ProfileTab.ownTabs.map(\.emptyState)
        #expect(Set(states.map(\.title)).count == states.count)
        #expect(Set(states.map(\.subtitle)).count == states.count)
        #expect(Set(states.map(\.symbol)).count == states.count)
    }

    @Test func everyTabCarriesAllThreeParts() {
        for state in ProfileTab.ownTabs.map(\.emptyState) {
            #expect(!state.symbol.isEmpty)
            #expect(!state.title.isEmpty)
            #expect(!state.subtitle.isEmpty)
        }
    }

    /// ⚠️ Every glyph resolves. A symbol name with a typo in it renders as
    /// nothing at all — the block loses its anchor and no test that only checks
    /// the string would notice.
    @Test func everyGlyphIsARealSymbol() {
        for state in ProfileTab.ownTabs.map(\.emptyState) {
            #expect(UIImage(systemName: state.symbol) != nil, "\(state.symbol) does not resolve")
        }
    }

    /// The copy itself, pinned — it was specified, so a change to it should be
    /// a decision rather than a drift.
    @Test func theCopyIsWhatWasAskedFor() {
        // Posts is every post since #631, and says so; the media gallery is
        // photos and videos.
        #expect(ProfileTab.format(.activity).emptyState.title == "No Posts Yet")
        #expect(ProfileTab.format(.activity).emptyState.subtitle == "Posts and reposts will appear here.")
        #expect(ProfileTab.format(.media).emptyState.title == "No Photos or Videos")
        #expect(ProfileTab.saved.emptyState.title == "No Saved Posts")
        #expect(ProfileTab.reactions.emptyState.title == "No Reactions Yet")

        #expect(ProfileTab.saved.emptyState.subtitle == "Posts you bookmark will appear here.")
        #expect(
            ProfileTab.reactions.emptyState.subtitle
                == "Posts you react to or like will show up here."
        )
    }
}
