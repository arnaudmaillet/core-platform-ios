import CoreModels
import CoreStorage
import DesignSystem
import HeroPage
import PostGrid
import ProfileData
import UIKit

/// What the tab pages ask of their screen (#2522): the view model, the
/// pager and its selector, the Channels tab's model and sheet, the last
/// gallery, and the bar and History's select mode a tab change moves.
@MainActor
protocol ProfileTabPagesHost: UIViewController {
    var viewModel: ProfileViewModel { get }
    var galleryPager: ProfileGalleryPagerView { get }
    var selector: HeroPageSelector { get }
    var selectorBar: PagedTabBar { get }
    var allTabs: [ProfileTab] { get }
    var channels: ProfileChannelsViewModel? { get }
    var makeChannelCreation: (@MainActor () -> UIViewController?)? { get }
    var lastGallerySnapshot: ProfileViewModel.GallerySnapshot? { get }
    func setSelectingHistory(_ selecting: Bool, restoresFoot: Bool)
    func applyNavigationState(animated: Bool)
}

/// The profile's tabs, out of `ProfileViewController` (#2522): which tabs
/// show, the selector's place and binding, the tab the page adopts, and
/// the Channels tab.
///
/// ⚠️ `mirrorSelection` IS RE-ENTRANT: a selection announces itself, by
/// design (see there).
@MainActor
final class ProfileTabPages {
    private unowned let host: any ProfileTabPagesHost

    init(host: any ProfileTabPagesHost, tabs: [ProfileTab]) {
        self.host = host
        self.tabs = tabs
    }

    /// Which pages this profile has. The viewer's own carries Saved and Liked;
    /// everyone else's does not, because neither pile is anybody else's to see.
    /// The tabs on show: Posts, and each other source once it has
    /// something in it (#742). One tab is no selector at all.
    private(set) var tabs: [ProfileTab]

    /// Wires the selector and the source filter, and puts the selector in its
    /// inline slot: a format tab records the selection and pages the gallery; a
    /// source pick re-filters every page in place.
    func configureFilterTray() {
        guard host.viewModel.hasGallery else { return }

        // Both ways (`HeroPageSelector.bind`): the lens tracks the pages, the
        // pill scrubs them, a reselect goes back to the top of the tab.
        host.selector.bind(to: host.galleryPager) { [weak self] index in self?.barSelectionChanged(index) }

        placeSelectors()

        // Land on the user's global preference: tab selection and pager page
        // adopt the (possibly stored) filter before first layout, so the
        // screen OPENS there — no visible jump. The preference names a FORMAT,
        // so it can only ever land on one of the three every profile has.
        let tab = ProfileTab.format(host.viewModel.galleryFilter.format)
        if let index = tabs.firstIndex(of: tab) {
            mirrorSelection(to: index)
        }
        host.galleryPager.setActivePage(tab, animated: false)

    }

    /// A tap on either selector: record the format, page the gallery, and carry
    /// the choice to the other bar so the hand-over has nothing to reconcile.
    private func barSelectionChanged(_ index: Int) {
        mirrorSelection(to: index)
        let tab = tabs[index]
        adoptTab(tab)
        host.galleryPager.setActivePage(tab, animated: host.selector.bar.animatesPageChanges)
    }

    /// Records the choice.
    ///
    /// ⚠️ Only a FORMAT page is a filter preference. Saved and Liked are
    /// corpora, not formats, and writing one into the stored filter would mean
    /// re-opening the profile on a tab the next profile may not even have.
    func adoptTab(_ tab: ProfileTab) {
        let changed = shownTab != tab
        shownTab = tab
        host.viewModel.setActiveTab(tab)
        // Off the History page: it takes in what was viewed (#2170), and its
        // select mode ends.
        if tab != .history {
            host.viewModel.releaseHistory()
            host.setSelectingHistory(false, restoresFoot: true)
        }
        // History's Select stands in ✎'s place, and only there (#2307):
        // leaving History past the threshold puts ✎ back, coming back brings
        // Select.
        if changed { host.applyNavigationState(animated: host.view.window != nil) }
    }

    /// The page on screen, as last adopted.
    private(set) var shownTab: ProfileTab?

    /// Selects a tab the way a selector tap does — the shared path behind the
    /// debug hook and the tests, so neither exercises a shortcut around the
    /// real one.
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        mirrorSelection(to: index)
        adoptTab(tabs[index])
        host.galleryPager.setActivePage(tabs[index], animated: false)
    }

    /// Puts the strip on a selection the pager reached by itself.
    ///
    /// ⚠️ THE RE-ENTRANCY LATCH WENT WITH THE SECOND COPY. It existed because
    /// `select` fires `.valueChanged`, whose action mirrored into the other
    /// bar, which selected again. With one strip the guard below is all of it.
    func mirrorSelection(to index: Int) {
        host.selector.select(index)
    }

    /// Gives the selector its home (#2475): the header at rest, where the
    /// action row stood, and the bar's leading group past the threshold —
    /// on every profile, the tab root as a pushed one
    /// (`HeroPageSelector.Placement.header`).
    ///
    /// ⚠️ ONE PAGE, NO SELECTOR (#631). A strip with one segment is a label
    /// pretending to be a control: the header then has no selector row.
    private func placeSelectors() {
        guard host.viewModel.hasGallery, tabs.count > 1, !host.selector.isPlaced else { return }
        host.selector.place(on: host)
        // Past the threshold already (a page that arrived late, #742): the
        // bar takes it at once.
        host.applyNavigationState(animated: host.view.window != nil)
    }

    /// Takes the selector away when one tab is left (#742) — out of the bar
    /// too, if it stood there.
    private func removeSelectors() {
        guard host.selector.isPlaced else { return }
        host.selector.remove(from: host)
        host.applyNavigationState(animated: host.view.window != nil)
    }

    /// The tabs whose source is still loading and which had posts the last
    /// time this profile was seen (`SectionPresenceStore`, #1773).
    static func rememberedTabs(
        _ tabs: [ProfileTab], in snapshot: ProfileViewModel.GallerySnapshot,
        screen: String?, presence: SectionPresenceStore
    ) -> [ProfileTab] {
        guard let screen else { return [] }
        return tabs.filter { tab in
            snapshot.state(for: tab) == .loading
                && (presence.count(screen: screen, section: String(describing: tab)) ?? 0) > 0
        }
    }

    /// ⚠️ NO TAB FOR A SOURCE WITH NOTHING IN IT (#742, the owner's call
    /// 2026-10-09) — Posts included since #1422 (owner, 2026-10-19). A tab
    /// shows once its source holds something; a source still loading waits,
    /// rather than showing a tab that might leave. Two exceptions:
    /// - the viewer's OWN Posts stays even empty: it is where the invitation
    ///   to post belongs;
    /// - with nothing shown at all, Posts is the one page — loading, "No
    ///   Posts Yet", or the lock of a private profile — so the area under
    ///   the header is never blank, which reads as still loading.
    ///
    /// A private profile the viewer does not follow thus shows Tagged alone
    /// when it has posts, plainly — no lock line (#1445) — and the lock alone
    /// when it has none; following it brings the tabs back as their sources
    /// fill. One tab left is no selector at all, in the header as in the
    /// bar.
    func showTabs(for snapshot: ProfileViewModel.GallerySnapshot) {
        var shown = Self.shownTabs(
            host.allTabs, in: snapshot, isOwnProfile: host.viewModel.isOwnProfile, hasChannels: showsChannelsTab
        )
        // ⚠️ SECTIONS BY PRESENCE (#1773): a source still loading whose tab
        // had posts last time keeps its tab from the first frame — it does
        // not pop in when its source answers.
        let remembered = Self.rememberedTabs(
            host.allTabs, in: snapshot, screen: host.viewModel.presenceScreen, presence: host.galleryPager.presence
        )
        shown = host.allTabs.filter { shown.contains($0) || remembered.contains($0) }
        shown = Self.withPostsBesideChannels(shown)
        if shown.isEmpty { shown = [.format(.activity)] }
        guard shown != tabs else { return }
        let active = tabs.indices.contains(host.galleryPager.activePageIndex) ? tabs[host.galleryPager.activePageIndex] : nil
        tabs = shown
        host.galleryPager.setVisibleTabs(shown)
        host.selectorBar.setTitles(shown.map(\.title))
        let index = active.flatMap { shown.firstIndex(of: $0) } ?? 0
        mirrorSelection(to: index)
        // ⚠️ THE PAGE ON SCREEN IS ADOPTED WHEN ITS TAB WENT (#772). An account
        // switch on Reposts or Tagged cuts the tabs to Posts while every source
        // reloads; the strip clamps quietly and the pager settles nothing, so
        // the source stayed on the tab that left — Posts then paged and pushed
        // "View all" from the wrong corpus.
        if active != shown[index] { adoptTab(shown[index]) }
        if shown.count > 1 {
            placeSelectors()
            // A strip in the bar re-fits to its new titles, the bell or the
            // chevron left where they are.
            host.applyNavigationState(animated: host.view.window != nil)
        } else {
            removeSelectors()
        }
    }

    /// The tabs `snapshot` gives something to show, in `all`'s order (#742,
    /// #1422): those whose source holds posts, and the viewer's own Posts.
    /// Empty when nothing has posts yet — `showTabs` then shows Posts alone.
    ///
    /// Channels (#2232) is no source of posts: it shows when the profile
    /// owns a channel the viewer may see (`hasChannels`), like any tab only
    /// with something in it.
    static func shownTabs(
        _ all: [ProfileTab], in snapshot: ProfileViewModel.GallerySnapshot, isOwnProfile: Bool,
        hasChannels: Bool = false
    ) -> [ProfileTab] {
        all.filter { tab in
            if tab == .channels { return hasChannels }
            if tab == .format(.activity), isOwnProfile { return true }
            if case .content(let posts) = snapshot.state(for: tab) { return !posts.isEmpty }
            return false
        }
    }

    /// ⚠️ CHANNELS NEVER STANDS ALONE (#2232): a profile with channels and
    /// no post yet — or a private one the viewer doesn't follow — keeps
    /// Posts first, so its "No Posts Yet" or its lock stays where the viewer
    /// looks for it, and the channels are the second tab. Pure, for tests.
    static func withPostsBesideChannels(_ shown: [ProfileTab]) -> [ProfileTab] {
        shown == [.channels] ? [.format(.activity), .channels] : shown
    }

    /// Whether Channels is a tab now (#2232): with a channel listed, or
    /// while its read is on its way for a profile that had one last time
    /// (sections by presence, #1773) — so it doesn't pop in under the
    /// viewer when the answer lands.
    private var showsChannelsTab: Bool {
        guard let channels = host.channels else { return false }
        if channels.hasChannels { return true }
        guard channels.phase == .loading, let screen = host.viewModel.presenceScreen else { return false }
        return (host.galleryPager.presence.count(screen: screen, section: Self.channelsPresenceSection) ?? 0) > 0
    }

    /// The key Channels' presence is remembered under (#1773).
    private static let channelsPresenceSection = String(describing: ProfileTab.channels)

    /// Follows the Channels model (#2232): its tab comes and goes with its
    /// channels, its page redraws, a refused write shakes its row's button,
    /// and "Create a Channel" presents the new channel's sheet.
    func bindChannels() {
        guard let channels = host.channels else { return }
        channels.onChange = { [weak self] in self?.channelsDidChange() }
        channels.onActionFailed = { [weak self] id in self?.channelsPage?.showFailure(for: id) }
        channels.onCreate = { [weak self] in self?.presentChannelCreation() }
    }

    /// The Channels page, once its tab has been shown.
    private var channelsPage: ProfileChannelsPage? {
        host.galleryPager.builtPage(for: .channels) as? ProfileChannelsPage
    }

    private func channelsDidChange() {
        guard let channels = host.channels else { return }
        if channels.phase == .loaded, let screen = host.viewModel.presenceScreen {
            host.galleryPager.presence.remember(
                channels.channels.count, screen: screen, section: Self.channelsPresenceSection
            )
        }
        let snapshot = host.lastGallerySnapshot ?? host.viewModel.publishedGallery
            ?? ProfileViewModel.GallerySnapshot(activity: .loading, media: .loading, isComplete: false)
        showTabs(for: snapshot)
        channelsPage?.render()
    }

    /// The new channel's sheet over the profile; Create lands in Messages
    /// with the channel's thread (#2230), and the profile lists it on the
    /// way back (`viewWillAppear`).
    private func presentChannelCreation() {
        guard host.presentedViewController == nil, let sheet = host.makeChannelCreation?() else { return }
        host.present(sheet, animated: true)
    }
}
