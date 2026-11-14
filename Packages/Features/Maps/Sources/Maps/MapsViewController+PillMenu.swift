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

// Pill menu destinations (#2388, out of the map's file)
extension MapsViewController {
    // MARK: - Pill menu destinations

    /// "Remove from Sub-filters": drop the refinement from the row, routed
    /// through the SAME adopt path the organize sheet commits on. That is what
    /// keeps one removal consistent everywhere — the hidden set is recomputed
    /// (so the next background refresh can't resurrect it), the order memory
    /// is rewritten, an applied refinement whose pill just left is dropped
    /// from the selection, and an emptied row retires itself.
    func removeSubFilterFromRow(_ subFilter: MapSubFilter) {
        let remaining = currentSubFilterOptions.filter { $0.subFilter != subFilter }
        guard remaining.count != currentSubFilterOptions.count else { return }
        adoptSubFilterOptions(remaining)
    }

    /// "View Details" on a place category. There is no place-detail screen in
    /// the app — place categories are client-side vocabulary, not entities the
    /// BFF can describe — so this does the most honest thing the surface can:
    /// isolates that category on the map, dropping every other refinement.
    /// Swap the body for a push once a real destination exists.
    func isolateSubFilter(_ subFilter: MapSubFilter) {
        let only: Set<MapSubFilter> = [subFilter]
        guard subFilterBar.selectedSubFilters != only else { return }
        subFilterBar.setSelectedSubFilters(only, reveal: subFilter)
        viewModel.subFiltersChanged(only)
    }

    /// "Share". Like the snap feed's share, this offers what the model
    /// actually carries: no canonical web URL for a profile or a place
    /// category exists on the wire yet, so the display name (and a person's
    /// `@handle`) stand in until one does.
    func presentShareSheet(for option: MapSubFilterOption) {
        var items: [Any] = [option.sheetTitle]
        if let subtitle = option.sheetSubtitle { items.append(subtitle) }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = subFilterBar
        present(activity, animated: true)
    }

    /// The sheet's committed arrangement, landing once when the viewer taps
    /// Done. The horizontal row restacks as the sheet slides away, so what is
    /// revealed is already right, and the edits are remembered for this
    /// primary so a later Friends → Places → Friends round trip doesn't
    /// silently rebuild the repository's list over the viewer's.
    /// Session-scoped and in memory: these are viewing preferences, not state
    /// the backend knows about. Cancel never reaches here at all.
    func adoptSubFilterOptions(_ options: [MapSubFilterOption]) {
        let surviving = Set(options.map(\.subFilter))
        currentSubFilterOptions = options

        if let primary = filterBar.selectedFilter {
            // Its order, and what is in the catalogue but not in the row
            // (see `MapSubFilterRowMemory.adopt`).
            subFilterMemory.adopt(options, for: primary)
            // ...and for a PEOPLE row the arrangement is now curation, not a
            // session preference: the same list the profile's star writes.
            // Persisting it here is what makes "+ → add → Done" survive the
            // next launch, and what keeps the two editors from disagreeing.
            if let category = MapSubFilterRowMemory.railCategory(for: primary) {
                let ids = options.compactMap(\.favorite?.profileID)
                pinService.setCuratedList(ids, in: category)
            }
        }
        // A refinement can't outlive its pill: any applied refinement whose
        // row left the bar is dropped from the selection.
        let stillApplied = subFilterBar.selectedSubFilters.intersection(surviving)
        if stillApplied != subFilterBar.selectedSubFilters {
            subFilterBar.setSelectedSubFilters(stillApplied)
            viewModel.subFiltersChanged(stillApplied)
        }
        // Emptying the row leaves the "+" standing rather than retiring the
        // bar: the viewer has just curated everyone off, and the one thing
        // they will want next is a way to put someone back.
        subFilterBar.restack(to: options)
        setSubFilterBar(visible: true)
        // ⚠️ RECORD what was just rendered — do not clear it.
        //
        // Clearing looked harmless ("let the next refresh apply whatever it
        // finds") and was the flash: every edit here writes the rail, the
        // store's change notification re-runs the refresh, and a nil yardstick
        // makes that refresh a `.swap` — so the pill the viewer removed
        // animated out politely and the whole row cross-dissolved on top of
        // it. With the state recorded, the refresh resolves to `.unchanged`
        // (or at worst a `.diff`), and the removal is the only thing that
        // moves.
        renderedSubFilterRow = filterBar.selectedFilter.flatMap { primary in
            MapSubFilterRowMemory.railCategory(for: primary) == nil
                ? nil // Places: not a people row, so it has no state to compare
                : subFilterMemory.rowState(primary: primary, people: options.compactMap(\.favorite))
        }
    }

    /// Pin/unpin a person pill. The rule — including materializing the
    /// never-curated fallback on the first write — belongs to
    /// `MapProfilePinService`, which the profile screen's pin button shares;
    /// the rail then refreshes off the store's change notification rather than
    /// here, so a pin made anywhere lands the same way.
    func togglePinnedFavorite(_ favorite: MapFavorite) {
        let pinService = pinService
        let id = favorite.profileID
        // These pills ARE the dock, so that is the rail this toggles — the
        // sub-filter rows are edited from the row itself (and from a profile's
        // star), not from here.
        Task {
            var categories = await pinService.categories(for: id)
            if categories.contains(.dock) {
                categories.remove(.dock)
            } else {
                categories.insert(.dock)
            }
            await pinService.setCategories(categories, for: id)
        }
    }

    /// Pure cross-dissolve show/hide. Structure (`isHidden`, stack layout)
    /// always lands OUTSIDE animation blocks: animating `isHidden` on the
    /// arranged subview made the stack interpolate the freshly-laid-out
    /// pills from zero frames — the accordion unfold. The main bar never
    /// moves either way (the stack's BOTTOM is pinned; the row grows upward
    /// into free map space), so nothing but opacity needs animating.
    func setSubFilterBar(visible: Bool) {
        guard visible != isSubFilterBarVisible else { return }
        isSubFilterBarVisible = visible
        if visible {
            // Un-collapse and lay out at full width while still transparent…
            UIView.performWithoutAnimation {
                subFilterBar.isHidden = false
                barsStack.layoutIfNeeded()
            }
            // …then fade the finished row in, in place (spring-settled,
            // zero bounce — opacity never overshoots).
            UIView.mapBarFade { self.subFilterBar.alpha = 1 }
        } else {
            UIView.mapBarFade(
                { self.subFilterBar.alpha = 0 },
                completion: { _ in
                    // Collapse only after the fade settles — and only if a
                    // re-show didn't land while the fade-out was in flight.
                    guard !self.isSubFilterBarVisible else { return }
                    self.subFilterBar.isHidden = true
                }
            )
        }
    }

    /// Loads the DOCK: the carousel of people pills in the main bar, visible
    /// whatever primary is selected. The curated `.dock` list when there is
    /// one, else the followed profiles — what this carousel has always shown.
    /// Fail-open: an empty result leaves the bar with just its primaries.
    ///
    /// Deliberately NOT scoped to the active primary. The dock is the
    /// top-level filter, and a top-level filter that changes contents when you
    /// pick a primary is a different control wearing the same pills. The two
    /// sub-filter ROWS are where a primary's own people live — see
    /// `people(for:)`.
    /// How long the dock waits before asking for its people again after a
    /// failed read.
    static let favoritesRetryDelay: TimeInterval = 5
    static let favoritesRetryLimit = 3

    func loadFavorites() {
        #if DEBUG
        // Which surface a write woke is the whole question when the complaint
        // is "the other bar flashed", and it is invisible in a screenshot.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-maps-toggle-subfilter") || arguments.contains("-maps-subfilter-remove")
            || arguments.contains("-maps-pin-favorite") {
            print("[maps] dock reload requested")
        }
        #endif
        favoritesTask?.cancel()
        guard isMember() else {
            currentFavorites = []
            filterBar.setFavorites([])
            return
        }
        let repository = favoritesRepository
        let curated = pinService.curatedProfileIDs(in: .dock)
        let writer = peopleCache?.viewer
        favoritesTask = Task { [weak self] in
            let people = if let curated {
                await repository.profiles(for: curated)
            } else {
                await repository.followingIfReachable()
            }
            guard let self, !Task.isCancelled else { return }
            // ⚠️ A FAILURE IS NOT "NO ONE" (#1767): it read as an empty dock,
            // the pills gone. The pills on show stay, and the dock asks again
            // a little later.
            guard let people else {
                // A few times, not forever: offline for good, the next reload
                // (a tab return, a filter change) asks again.
                guard self.favoritesRetries < Self.favoritesRetryLimit else { return }
                self.favoritesRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.favoritesRetryDelay) { [weak self] in
                    self?.loadFavorites()
                }
                return
            }
            self.favoritesRetries = 0
            self.currentFavorites = people
            self.filterBar.setFavorites(people)
            self.peopleCache?.store(people, in: .dock, as: writer)
        }
    }

    /// The people a primary's sub-filter row shows: the viewer's curated list
    /// for that row when they have one, else the graph behind it.
    ///
    /// The Friends row additionally INTERSECTS with the live mutual set, so
    /// someone who stops following back leaves the row even though the viewer
    /// once put them there — the row means "friends", and it keeps meaning
    /// that. Their dock pill and their Following row entry are untouched, and
    /// they come back here if they follow back again (the stored list is never
    /// edited for this — see `MapProfilePinService`).
    func people(for primary: MapFilter) async -> [MapFavorite] {
        let repository = favoritesRepository
        guard let curated = pinService.curatedProfileIDs(in: primary == .friends ? .friends : .following)
        else {
            return primary == .friends ? await repository.friends() : await repository.following()
        }
        let people = await repository.profiles(for: curated)
        guard primary == .friends else { return people }
        let mutuals = Set(await repository.friends().map(\.profileID))
        return people.filter { mutuals.contains($0.profileID) }
    }

    /// Fades both filter bars with the tab bar around the snap-feed flight:
    /// they belong to the map's resting chrome, and lingering pills under a
    /// flying hero card read as debris. Mirrors the manual tab-bar
    /// choreography (hide at lift-off, restore only on the completed pop).
    func setFilterBar(hidden: Bool) {
        UIView.animate(withDuration: 0.2) { [barsStack] in
            barsStack.alpha = hidden ? 0 : 1
        }
    }

    func bindViewModel() {
        viewModel.onDiff = { [weak self] diff in self?.handleDiff(diff) }
        // Queries failing in a row (#798): the pins stay, the toast says the
        // map is not up to date. The view model says it once per run.
        // `Feedback` puts it on the topmost presented screen: a sheet over the
        // map (a marker preview, the sub-filter sheet) would otherwise cover it.
        viewModel.onRepeatedQueryFailure = { [weak self] message in
            guard let self else { return }
            Feedback.failure(message, from: self)
        }
        // `onTileCount` is a "zoom in for more" hint hook; wired to UI later.
    }

    /// Folds a diff into the raw model, then re-lays-out the markers — unless a
    /// region change is animating, in which case the layout waits for the
    /// settle (`regionDidChange`), so markers are never restacked mid-flight.
    private func handleDiff(_ diff: MapAnnotationDiff) {
        for pin in diff.removed { pins[pin.postID] = nil }
        for pin in diff.added { pins[pin.postID] = pin }
        for pin in diff.updated { pins[pin.postID] = pin }
        if isRegionTransitioning {
            layoutPending = true
        } else {
            #if DEBUG
            MapChurnCounters.fromDiff += 1
            #endif
            reconcileClusters()
        }
    }

    /// The settle path's reconcile, throttled while the camera is purely panning.
    ///
    /// A pan at an unchanged span cannot change the layout: `MapClusterEngine`
    /// grids on ABSOLUTE `MKMapPoint`s with `cell = cellPoints / zoomScale`, so
    /// the viewport centre is not one of its inputs. Measured under
    /// `-maps-nav-drag` (60 Hz stepped pan, the cadence a finger produces):
    /// **55.6 reconciles/s producing 0 arrivals and 0 rebinds, costing 65 ms/s
    /// of main thread** — 6.5%, against 0.67% under `-maps-nav-sweep`, which
    /// calls `setRegion(animated:)` and so fires this delegate once per gesture
    /// instead of once per frame. The scripted sweep could not see this at all,
    /// and the first version of this analysis concluded there was nothing here.
    ///
    /// ⚠️ It DEFERS, it never drops. The trailing item always runs, so the
    /// layout converges even if the camera stops between two callbacks — a
    /// throttle that skipped the last callback would leave the map permanently
    /// wrong wherever the finger happened to lift.
    ///
    /// A zoom is never throttled. A changed span is exactly the case where the
    /// layout does move, and it is also the case the user is watching.
    func reconcileClustersForSettle() {
        // The trailing item can land mid-flight, which the settle path never
        // could — `regionDidChangeAnimated` has just cleared the flag when it
        // calls in. Restacking mid-flight is exactly what `isRegionTransitioning`
        // exists to prevent, so hand it to the settle the same way a mid-flight
        // diff is handed over.
        if isRegionTransitioning {
            layoutPending = true
            return
        }
        // ⚠️ OFF BY DEFAULT — it is a MEASURED REGRESSION, kept only so the
        // experiment stays reproducible. `-maps-reconcile-throttle` enables it.
        //
        // It does exactly what it claims: 3 paired 60-second runs, fresh launch
        // per arm, under `-maps-nav-drag`.
        //
        //            reconcile/s   ms/s    cpu    frame    p95   hitches
        //   control       37.21   48.83  48.5%   21.13  38.58     20.87
        //   throttled      7.82   13.30  46.4%   22.01  40.46     28.23
        //
        // 79% of reconciles and 73% of their main-thread time removed — tight
        // across all three reps — and the frame, the p95 and the hitches all got
        // WORSE, every throttled rep above the control's mean. Removing work
        // from the main thread made the map stutter more.
        //
        // The likely mechanism is WHEN, not how much: the inline reconciles ran
        // synchronously inside the region-change callback, a moment the frame
        // had already conceded, while the trailing `asyncAfter` lands at an
        // arbitrary point that can be mid-frame. At 1.3 ms a piece, scheduling
        // dominates volume.
        //
        // ⚠️ A single earlier pair showed hitches 30.9 -> 17.2 and nearly shipped
        // as a 44% win. The control arm alone swings 17.4-27.7 between runs.
        // One pair could not have told these apart.
        guard Self.reconcileThrottleEnabled else {
            #if DEBUG
            MapChurnCounters.fromSettle += 1
            #endif
            reconcileClusters()
            return
        }
        let zoom = currentZoomScale
        guard zoom > 0 else { reconcileClusters(); return }
        let snapped = MapClusterEngine.snapZoom(zoom)
        let now = CACurrentMediaTime()
        let isPurePan = lastSettleSnappedZoom == snapped
        if isPurePan, now - lastSettleReconcileAt < Self.panReconcileInterval {
            #if DEBUG
            MapChurnCounters.settleThrottled += 1
            #endif
            // ⚠️ ARM ONCE. Cancel-and-reschedule is a DEBOUNCE, and a debounce
            // waits for quiet — under a 60 Hz pan the item is cancelled every
            // 16 ms and never fires at all. The first version did exactly that
            // and emptied the map: the opening reconcile ran before the first
            // query returned, every later one was starved, and the readout said
            // `markers 0.0` while every performance column improved. A throttle
            // arms on the first deferred call and lets it land.
            guard trailingSettleReconcile == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.trailingSettleReconcile = nil
                self?.reconcileClustersForSettle()
            }
            trailingSettleReconcile = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (Self.panReconcileInterval - (now - lastSettleReconcileAt)),
                execute: work
            )
            return
        }
        trailingSettleReconcile?.cancel()
        trailingSettleReconcile = nil
        lastSettleSnappedZoom = snapped
        lastSettleReconcileAt = now
        #if DEBUG
        MapChurnCounters.fromSettle += 1
        #endif
        reconcileClusters()
    }

    func flushPendingDiffs() {
        guard layoutPending else { return }
        layoutPending = false
        #if DEBUG
        MapChurnCounters.fromFlush += 1
        #endif
        reconcileClusters()
    }
}
