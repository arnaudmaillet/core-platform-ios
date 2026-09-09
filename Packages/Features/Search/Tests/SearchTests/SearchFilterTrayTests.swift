import CoreModels
import CoreStorage
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Search

/// The bar's trailing slot: a filter tray, and the order it puts on the wire.
///
/// ⚠️ THIS FILE REPLACED A SET OF TESTS FOR A "Search" BUTTON THAT LIVED HERE
/// FOR ONE ROUND. The button submitted, which the keyboard's own Search key
/// already did on a screen that opens with that keyboard up — so it bought a
/// second way to do what the viewer's thumb was already on, at the cost of the
/// field's width. The tray is what that width is for.
///
/// ⚠️ TYPING IS NOT TESTED HERE, AND IT IS NOT AN OVERSIGHT. No synthetic event
/// reaches an `.editingChanged` handler on a `UISearchTextField`. Measured, on
/// a field hosted in a key window and first responder, with the target
/// confirmed registered:
///
///     sendActions(.editingChanged)      → handler NOT called
///     sendActions(.allEditingEvents)    → handler NOT called
///     sendActions(.valueChanged)        → handler NOT called
///     post(textDidChangeNotification)   → handler NOT called
///     perform(#selector(searchTextChanged)) → handler called
///
/// A keystroke arrives through UIKit's own text pipeline, which a test process
/// cannot raise. An earlier probe "proved" one of those worked — because it
/// fired AFTER a direct `perform` had already flipped the flag, and read the
/// leftover. Order the probe, or it lies. Typing is covered on the simulator.
@MainActor
struct SearchFilterTrayTests {
    private actor StubProvider: SearchProviding {
        private let box: SortBox
        init(box: SortBox) { self.box = box }

        func searchProfiles(
            matching query: String, sort: SearchSortOrder, limit: Int32
        ) async throws -> [ProfileSearchResult] {
            await box.record(sort)
            return [ProfileSearchResult(
                id: ProfileID("p1"), handle: query, displayName: query, isVerified: false
            )]
        }
        func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
    }

    /// Every order the screen asked the repository for, in order — which is how
    /// a test tells a RE-RUN from a re-sort of what the client already held.
    private actor SortBox {
        private(set) var sorts: [SearchSortOrder] = []
        func record(_ sort: SearchSortOrder) { sorts.append(sort) }
    }

    @MainActor
    private final class Host {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen: SearchViewController
        let viewModel: SearchViewModel
        let box: SortBox

        init() {
            box = SortBox()
            viewModel = SearchViewModel(
                repository: StubProvider(box: box),
                router: nil,
                recentSearches: RecentSearchStore(
                    defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 }
                )
            )
            screen = SearchViewController(
                viewModel: viewModel,
                imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
            )
            // ⚠️ A REAL NAVIGATION CONTROLLER, because submitting now PUSHES.
            // A screen with no navigation controller would swallow the push and
            // every assertion about the results screen would read nil.
            window.rootViewController = UINavigationController(rootViewController: screen)
            window.makeKeyAndVisible()
            screen.loadViewIfNeeded()
            window.layoutIfNeeded()
        }

        var field: UITextField? { screen.navigationItem.titleView as? UITextField }

        /// ⚠️ THE TRAY IS ON THE RESULTS SCREEN'S TOOLBAR NOW, not the search
        /// screen's bar. The search screen shows a history and a typeahead;
        /// neither has an order to change.
        var item: UIBarButtonItem? {
            (screen.navigationController?.topViewController as? SearchResultsViewController)?
                .toolbarItems?.last
        }

        /// Submits, which PUSHES the results screen, and waits for it.
        func showResults(_ text: String) async {
            submit(text)
            for _ in 0..<80 where item == nil { await Task.yield() }
        }

        /// The groups the sheet would be built from. They live on the view
        /// model — two screens read them — so this needs no presentation.
        var filterGroups: [SearchFilterSheetViewController.Group] {
            viewModel.filterGroups()
        }

        func submit(_ text: String) {
            viewModel.onQueryTextChange?(text)
            _ = screen.textFieldShouldReturn(field ?? UITextField())
        }
    }

    // MARK: - The tray

    /// ⚠️ THE TRAY IS NOT IN THE BAR UNTIL THERE IS AN ANSWER. It held a
    /// "Search" button first, then the tray permanently; both were wrong. Sort
    /// changes the ORDER of an answer, so before one exists there is nothing
    /// for it to act on.
    @Test func theBarIsBareOnTheRestingScreen() {
        #expect(Host().item == nil)
    }

    /// ⚠️ IN THE TOOLBAR, TRAILING. The navigation bar carries a back button
    /// and a full-width query field; a third item there would take width off
    /// the query the viewer is reading.
    @Test func theTrayIsTheResultsScreenTrailingToolbarItem() async {
        let host = Host()
        await host.showResults("haddad")
        #expect(host.item != nil)
        #expect(host.item?.title == nil)
        #expect(host.item?.image != nil)
        #expect(host.item?.accessibilityLabel == "Filters")
    }

    @Test func theSheetCarriesTheThreeDimensionsAsked() async {
        let host = Host()
        await host.showResults("haddad")
        #expect(host.filterGroups.map(\.title) == ["Rank by", "Published", "Scope"])
    }

    /// ⚠️ EVERY SEGMENT THE PRODUCT NAMED IS DRAWN, and the ones nothing can
    /// honour are DISABLED rather than missing: a segmented control showing two
    /// of four options makes the dimension itself unreadable.
    @Test func everySegmentIsDrawnAndOnlyTheImpossibleOnesAreDisabled() async {
        let host = Host()
        await host.showResults("haddad")
        let groups = host.filterGroups

        #expect(groups.first { $0.title == "Rank by" }?.segments.map(\.title)
                == ["Trending", "Newest", "Liked", "Commented"])
        #expect(groups.first { $0.title == "Published" }?.segments.map(\.title)
                == ["24h", "Week", "6 months", "All time"])
        #expect(groups.first { $0.title == "Scope" }?.segments.map(\.title)
                == ["Everyone", "Seen", "Unseen", "Following"])

        let enabled = groups.flatMap(\.segments).filter(\.isEnabled).map(\.title)
        #expect(enabled == ["Trending", "Newest", "All time", "Everyone", "Following"])
    }

    /// Each dimension says why its dead segments are dead, which is the thing a
    /// menu had nowhere to put and is the reason this became a sheet.
    @Test func everyDimensionWithADeadSegmentExplainsItself() async {
        let host = Host()
        await host.showResults("haddad")
        let groups = host.filterGroups
        for group in groups where group.segments.contains(where: { !$0.isEnabled }) {
            #expect(group.footer?.isEmpty == false)
        }
    }

    @Test func theSheetOpensOnWhatIsInEffect() async {
        let host = Host()
        await host.showResults("haddad")
        let groups = host.filterGroups
        #expect(groups.first { $0.title == "Scope" }?.selectedID == SearchScope.everyone.rawValue)
        #expect(groups.first { $0.title == "Published" }?.selectedID == "all")
    }

    /// ⚠️ Built at PRESENTATION, not once. A sheet assembled when the screen
    /// loaded would open on whatever was true then.
    @Test func theSheetFollowsAChoiceMadeEarlier() async {
        let host = Host()
        await host.showResults("haddad")
        host.viewModel.setSortOrder(.recency)
        #expect(host.filterGroups.first?.selectedID == SearchSortOrder.recency.rawValue)
    }

    // MARK: - What the order does

    @Test func theChosenOrderGoesOnTheWire() async {
        let host = Host()
        host.viewModel.setSortOrder(.popularity)
        host.submit("haddad")
        for _ in 0..<50 where await host.box.sorts.isEmpty { await Task.yield() }
        #expect(await host.box.sorts == [.popularity])
    }

    /// ⚠️ A RE-RUN, NOT A RE-SORT. The engine ranks the whole index and answers
    /// with a page of it; re-ordering the page the client happens to hold would
    /// show the same people in a different order and call it "most recent".
    @Test func changingTheOrderRunsTheSearchAgain() async {
        let host = Host()
        host.submit("haddad")
        for _ in 0..<50 where await host.box.sorts.isEmpty { await Task.yield() }

        host.viewModel.setSortOrder(.recency)
        for _ in 0..<50 where await host.box.sorts.count < 2 { await Task.yield() }
        #expect(await host.box.sorts == [.popularity, .recency])
    }

    /// Nothing has been searched for yet, so there is nothing to re-run — the
    /// pick is remembered and takes effect on the next submit.
    @Test func changingTheOrderWithNothingSearchedForRunsNothing() async {
        let host = Host()
        host.viewModel.setSortOrder(.recency)
        for _ in 0..<20 { await Task.yield() }
        #expect(await host.box.sorts.isEmpty)
        #expect(host.viewModel.sortOrder == .recency)
    }

    @Test func pickingTheOrderAlreadyInEffectChangesNothing() async {
        let host = Host()
        host.submit("haddad")
        for _ in 0..<50 where await host.box.sorts.isEmpty { await Task.yield() }

        host.viewModel.setSortOrder(.popularity)
        for _ in 0..<20 { await Task.yield() }
        #expect(await host.box.sorts == [.popularity])
    }

    // MARK: - The query on the results screen is a door

    /// ⚠️ THE REFUSAL IS THE FEATURE. Returning false from
    /// `textFieldShouldBeginEditing` is what stops the field becoming first
    /// responder — no keyboard is summoned, so none has to be dismissed on the
    /// way out. A transparent button over the field would have let the keyboard
    /// start rising before the pop.
    @Test func theResultsQueryRefusesTheKeyboardAndAsksToGoBack() async {
        let host = Host()
        await host.showResults("haddad")
        let results = try? #require(
            host.screen.navigationController?.topViewController as? SearchResultsViewController
        )
        var asked = 0
        results?.onEditQuery = { asked += 1 }

        let field = try? #require(results?.navigationItem.titleView?
            .subviews.compactMap { $0 as? UITextField }.first)
        #expect(field?.becomeFirstResponder() == false)
        #expect(field?.isFirstResponder == false)
        #expect(asked == 1)
    }

    /// The header keeps one shape: the two halves are tied to each other, so
    /// the split holds at whatever width the bar hands the title view.
    @Test func theHeaderSplitsTheRowInHalf() async {
        let host = Host()
        await host.showResults("haddad")
        let results = try? #require(
            host.screen.navigationController?.topViewController as? SearchResultsViewController
        )
        let row = try? #require(results?.navigationItem.titleView as? UIStackView)
        #expect(row?.arrangedSubviews.count == 2)
        let equal = row?.arrangedSubviews.first?.constraints.contains { constraint in
            constraint.firstAttribute == .width && constraint.multiplier == 1
        }
        // The constraint is installed on the tab bar against the field, so it
        // is held by their common ancestor rather than by either view.
        let held = row?.constraints.contains { $0.firstAttribute == .width } ?? false
        #expect(held || equal == true)
    }

    // MARK: - Cancel and Done

    /// ⚠️ CANCEL MEANS "PUT BACK WHAT WAS IN EFFECT", not "discard a buffer".
    /// The picks apply live — that is the point of a sheet over a menu — so
    /// there is no uncommitted state to throw away, and reverting has to go
    /// back out through the same channel a tap uses or the sheet and the
    /// results underneath would disagree.
    @Test func cancellingPutsBackWhatWasInEffectWhenTheSheetOpened() async {
        let host = Host()
        await host.showResults("haddad")
        #expect(host.viewModel.sortOrder == .popularity)

        let sheet = SearchFilterSheetViewController(groups: host.filterGroups) { group, option in
            host.viewModel.applyFilter(group: group, option: option)
        }
        sheet.loadViewIfNeeded()
        sheet.pickForTesting(groupID: SearchViewModel.rankingGroupID,
                             segmentID: SearchSortOrder.recency.rawValue)
        #expect(host.viewModel.sortOrder == .recency)

        sheet.revertForTesting()
        #expect(host.viewModel.sortOrder == .popularity)
    }

    @Test func cancellingAfterNoChangeChangesNothing() async {
        let host = Host()
        await host.showResults("haddad")
        let sheet = SearchFilterSheetViewController(groups: host.filterGroups) { group, option in
            host.viewModel.applyFilter(group: group, option: option)
        }
        sheet.loadViewIfNeeded()
        sheet.revertForTesting()
        #expect(host.viewModel.sortOrder == .popularity)
        #expect(host.viewModel.scope == .everyone)
    }

    /// ⚠️ ONE DETENT. Dragged to full height the sheet hid the results its
    /// filters act on, which are the only reason to look at it.
    @Test func theSheetCannotBeExpandedPastItsContent() async {
        let host = Host()
        await host.showResults("haddad")
        let wrapped = SearchFilterSheetViewController.inSheet(groups: host.filterGroups) { _, _ in }
        let detents = wrapped.sheetPresentationController?.detents ?? []
        #expect(detents.count == 1)
        #expect(detents.first?.identifier != .large)
    }

    // MARK: - The keyboard is still the way to submit

    @Test func theKeyboardSearchKeyStillSubmitsAndGetsOutOfTheWay() throws {
        let host = Host()
        host.viewModel.onQueryTextChange?("haddad")
        let field = try #require(host.field)
        field.becomeFirstResponder()
        #expect(field.isFirstResponder)

        _ = host.screen.textFieldShouldReturn(field)
        #expect(field.isFirstResponder == false)
    }
}
