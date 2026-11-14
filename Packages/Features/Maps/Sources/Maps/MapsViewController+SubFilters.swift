import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import LocalStore
import MapKit
import MapsInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

// The sub-filter row (#2388, out of the map's file)
extension MapsViewController {
    // MARK: - Sub-filter row

    /// Warms the people cache once at screen load (both lists in parallel),
    /// so the first Friends/Following tap already has its row in memory.
    func prefetchPeople() {
        guard isMember() else { return }
        let repository = favoritesRepository
        // The viewer the lists are read for, captured BEFORE the fetch.
        let writer = peopleCache?.viewer
        Task { [weak self] in
            async let friends = repository.friends()
            async let following = repository.following()
            let (friendsList, followingList) = await (friends, following)
            guard let self else { return }
            self.subFilterMemory.catalogue[.friends] = friendsList
            self.subFilterMemory.catalogue[.following] = followingList
            // The rows themselves may be curated subsets; resolve them from
            // the same lists rather than assuming the graph IS the row.
            let friendsRow = await self.people(for: .friends)
            self.subFilterMemory.people[.friends] = friendsRow
            let followingRow = await self.people(for: .following)
            self.subFilterMemory.people[.following] = followingRow
            self.storePeople(primary: .friends, row: friendsRow, catalogue: friendsList, as: writer)
            self.storePeople(primary: .following, row: followingRow, catalogue: followingList, as: writer)
        }
    }

    /// The last people of the dock and both rows (#1776), on the first frame:
    /// the dock's pills and a primary's first tap need no network. The fetches
    /// that follow revalidate them in place. Never after a viewer change:
    /// that path goes straight to the network (the wipe may not have run).
    func restorePeople() {
        guard isMember(), let peopleCache else { return }
        if let dock = peopleCache.people(.dock), !dock.isEmpty {
            currentFavorites = dock
            filterBar.setFavorites(dock)
        }
        for primary in [MapFilter.friends, .following] {
            if let slot = MapPeopleLocalCache.Slot.row(primary), let row = peopleCache.people(slot) {
                subFilterMemory.people[primary] = row
            }
            if let slot = MapPeopleLocalCache.Slot.catalogue(primary), let catalogue = peopleCache.people(slot) {
                subFilterMemory.catalogue[primary] = catalogue
            }
        }
    }

    private func storePeople(
        primary: MapFilter, row: [MapFavorite], catalogue: [MapFavorite], as writer: LocalStoreViewer?
    ) {
        guard let peopleCache, let rowSlot = MapPeopleLocalCache.Slot.row(primary),
              let catalogueSlot = MapPeopleLocalCache.Slot.catalogue(primary) else { return }
        peopleCache.store(row, in: rowSlot, as: writer)
        peopleCache.store(catalogue, in: catalogueSlot, as: writer)
    }

    /// Repopulates (or hides) the refinement row for a newly selected
    /// primary. UI first, data second: the row renders SYNCHRONOUSLY from
    /// the session cache (0ms — never awaiting the network), then a
    /// background refresh re-renders only if the list actually changed and
    /// the selection hasn't moved on.
    func updateSubFilterBar(for filter: MapFilter?) {
        subFilterLoadTask?.cancel()
        switch filter {
        case .friends, .following:
            guard let primary = filter else { return } // matched .some above
            // 1) Instant, and ALWAYS applied — not only when the cache has
            // something. Whatever is on screen belongs to the primary the
            // viewer just LEFT, so an empty target has to clear it rather than
            // inherit it. (It did inherit it: switching to an empty rail left
            // the previous primary's pills up.)
            applyPeopleRow(subFilterMemory.people[primary] ?? [], for: primary)
            // A guest follows no one: the row stays empty, nothing is fetched.
            guard isMember() else { return }
            // 2) Refresh behind it (also the cold path pre-prefetch, where
            // the row fills in when data lands).
            let repository = favoritesRepository
            let writer = peopleCache?.viewer
            subFilterLoadTask = Task { [weak self] in
                guard let people = await self?.people(for: primary) else { return }
                let catalogue = primary == .friends
                    ? await repository.friends()
                    : await repository.following()
                guard let self, !Task.isCancelled else { return }
                self.subFilterMemory.catalogue[primary] = catalogue
                self.subFilterMemory.people[primary] = people
                self.storePeople(primary: primary, row: people, catalogue: catalogue, as: writer)
                guard self.filterBar.selectedFilter == primary else { return }
                self.applyPeopleRow(people, for: primary)
            }
        case .pinned:
            renderedSubFilterRow = nil
            showSubFilterRow(MapSubFilterOption.placeCategories)
        default:
            // All / a favorite: no refinement dimension.
            renderedSubFilterRow = nil
            currentSubFilterOptions = []
            setSubFilterBar(visible: false)
        }
    }

    /// Renders a people row for `primary`, or retires it — skipping only when
    /// the row is ALREADY showing exactly this.
    ///
    /// The comparison is against what is rendered, never against a cache: see
    /// `MapSubFilterRowUpdate` for the switch-to-an-empty-primary bug that
    /// distinction exists to prevent.
    private func applyPeopleRow(_ people: [MapFavorite], for primary: MapFilter) {
        let incoming = subFilterMemory.rowState(primary: primary, people: people)
        let update = MapSubFilterRowUpdate.resolve(rendered: renderedSubFilterRow, incoming: incoming)
        #if DEBUG
        // Which path a row edit took is invisible in a screenshot — a diff and
        // a cross-dissolve land on the same pixels and differ only in how they
        // got there. Printed alongside the toggle hook that provokes it.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-maps-toggle-subfilter") || arguments.contains("-maps-subfilter-remove") {
            let style = switch update {
            case .show(let options, let style): "show(\(options.count) pills, \(style))"
            case .hide: "hide"
            case .unchanged: "unchanged"
            }
            print("[maps] sub-filter row update: \(style) at \(CACurrentMediaTime())")
        }
        #endif
        switch update {
        case .unchanged:
            return
        case .hide:
            renderedSubFilterRow = incoming
            currentSubFilterOptions = []
            setSubFilterBar(visible: false)
        case .show(let options, let style):
            renderedSubFilterRow = incoming
            showSubFilterRow(options, style: style)
        }
    }

    /// One entry point for populating the row, choosing the right
    /// transition: hidden → set content and fade the bar in; already
    /// visible → cross-dissolve the pills in place (a hard swap while
    /// on-screen reads as a snap).
    private func showSubFilterRow(
        _ options: [MapSubFilterOption], style: MapSubFilterRowUpdate.Style = .swap
    ) {
        let options = subFilterMemory.ordered(options, for: filterBar.selectedFilter)
        currentSubFilterOptions = options
        guard isSubFilterBarVisible else {
            subFilterBar.setOptions(options)
            setSubFilterBar(visible: true)
            return
        }
        switch style {
        case .swap:
            // A different primary's list: one surface out, one in.
            subFilterBar.transition(to: options)
        case .diff:
            // The SAME list, edited — someone was added or removed from this
            // rail while the viewer was looking at it. Only the pills that
            // changed may move: cross-dissolving the row for a one-pill edit
            // is a flash, and it takes the scroll position and the selection
            // with it. `restack` is the animated diffable apply the organize
            // sheet already commits through.
            subFilterBar.restack(to: options)
            pruneSubFilterSelection(to: options)
        }
    }

    /// Drops any applied refinement whose pill just left the row. A selection
    /// can't outlive its pill: the map would stay filtered by someone the
    /// viewer can no longer see or unselect.
    ///
    /// Only the diff path needs this — a swap resets the selection with the
    /// content, and the organize sheet prunes as it commits.
    private func pruneSubFilterSelection(to options: [MapSubFilterOption]) {
        let surviving = Set(options.map(\.subFilter))
        let stillApplied = subFilterBar.selectedSubFilters.intersection(surviving)
        guard stillApplied != subFilterBar.selectedSubFilters else { return }
        subFilterBar.setSelectedSubFilters(stillApplied)
        viewModel.subFiltersChanged(stillApplied)
    }

    /// The header's organize button: the row's full contents as a searchable
    /// native bottom sheet, purely for arranging what the row carries. It
    /// applies nothing — the sheet edits a buffer and hands back a list on
    /// Done, or hands back nothing at all on Cancel.
    func presentSubFilterSheet() {
        // Gated on the CATALOGUE, not on the row: an empty row is exactly when
        // the sheet matters most (the "+" is the only way back), and the only
        // sheet worth refusing is one with nothing in either section.
        guard !subFilterMemory.catalogueOptions(for: filterBar.selectedFilter).isEmpty else { return }
        // Only the primaries that HAVE a refinement dimension get a sheet —
        // and the primary's own name is the sheet's title.
        guard let title = MapSubFilterRowMemory.title(for: filterBar.selectedFilter) else { return }
        let sheet = MapSubFilterSheetViewController.makeSheet(
            title: title,
            // The sheet shows the whole catalogue split in two: what the bar
            // carries, and everything else this primary could offer.
            all: subFilterMemory.catalogueOptions(for: filterBar.selectedFilter),
            activeSubFilters: currentSubFilterOptions.map(\.subFilter),
            // People rows hold a full rail (12); category rows hold 6.
            maxActive: MapSubFilterSections.maxActive(for: filterBar.selectedFilter),
            imagePipeline: imagePipeline,
            rowActions: MapSubFilterSheetViewController.RowActions(
                openProfile: { [weak self] favorite in self?.openProfile(favorite) },
                toggleMute: { [weak self] favorite in
                    self?.subFilterMemory.toggleMute(favorite.profileID)
                },
                isMuted: { [weak self] id in self?.subFilterMemory.isMuted(id) ?? false }
            ),
            onOptionsChanged: { [weak self] options in
                self?.adoptSubFilterOptions(options)
            }
        )
        present(sheet, animated: true)
    }

    /// The sheet's Profile swipe. Maps stays navigation-agnostic (the tab
    /// coordinator owns routing), so this hands the shell an id plus the
    /// identity it already has on screen — the destination renders its header
    /// from the stub instead of flashing empty while the profile loads.
    func openProfile(_ favorite: MapFavorite) {
        openProfile(favorite.profileID, Self.stub(of: favorite))
    }

    /// What the pill shows of a favourite — a person the viewer follows —
    /// for the destination it opens (#1860): its name, handle and face.
    static func stub(of favorite: MapFavorite) -> ProfileIdentityStub {
        ProfileIdentityStub(
            handle: favorite.handle, displayName: favorite.title, isFollowing: true, avatarURL: favorite.avatarURL
        )
    }
}
