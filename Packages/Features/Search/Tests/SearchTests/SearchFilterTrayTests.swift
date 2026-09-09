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
        let navigation: UINavigationController
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
            // ⚠️ HELD DIRECTLY, not reached through the screen. Submitting
            // REPLACES the search screen in the stack — that is the point of it
            // — so `screen.navigationController` is nil from then on, and any
            // helper that went through the screen would read nil for the
            // results it was asked about.
            navigation = UINavigationController(rootViewController: screen)
            window.rootViewController = navigation
            window.makeKeyAndVisible()
            screen.loadViewIfNeeded()
            window.layoutIfNeeded()
        }

        var field: UITextField? { screen.navigationItem.titleView as? UITextField }

        /// ⚠️ THE TRAY IS ON THE RESULTS SCREEN'S TOOLBAR NOW, not the search
        /// screen's bar. The search screen shows a history and a typeahead;
        /// neither has an order to change.
        var results: SearchResultsViewController? {
            navigation.topViewController as? SearchResultsViewController
        }

        var item: UIBarButtonItem? { results?.toolbarItems?.last }

        /// Submits, which PUSHES the results screen, and waits for it.
        func showResults(_ text: String) async {
            submit(text)
            for _ in 0..<80 where item == nil { await Task.yield() }
        }

        /// ⚠️ THE PUSH IS SYNCHRONOUS AND THE ANSWER IS NOT. `showResults`
        /// returns as soon as the screen exists, which is before the search has
        /// come back — a test that asserted on the phase straight after it read
        /// `.loading` and called a working screen broken.
        func settleAnswer() async {
            for _ in 0..<80 {
                if case .results = viewModel.currentPhase { return }
                if case .empty = viewModel.currentPhase { return }
                await Task.yield()
            }
        }

        /// ⚠️ `settleAnswer()` CANNOT TELL ONE ANSWER FROM THE NEXT. It returns
        /// the moment the phase is `.results`, which it already is after the
        /// first query — so a test that submits a SECOND query and calls it
        /// reads the first answer and believes it waited. This waits for the
        /// words to change.
        func settleAnswer(showing handle: String) async {
            for _ in 0..<200 {
                if case .results(let models) = viewModel.currentPhase,
                   models.first?.handle == handle { return }
                await Task.yield()
            }
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

    // MARK: - Where Back goes, and asking again

    /// ⚠️ THE SEARCH SCREEN LEAVES THE STACK AS THE ANSWER ARRIVES, so Back on
    /// the results screen reaches the ORIGIN. A viewer who has an answer is
    /// done asking; walking them back through the question is a step nobody
    /// wants.
    @Test func submittingReplacesTheSearchScreenRatherThanStackingOnIt() async {
        let host = Host()
        let origin = host.navigation.viewControllers.first
        await host.showResults("haddad")

        let stack = host.navigation.viewControllers
        #expect(stack.count == 1)
        #expect(stack.first is SearchResultsViewController)
        // The screen that was pushed FROM is gone with it — this test's origin
        // IS the search screen, so a stack of one proves the replacement.
        #expect(origin === host.screen)
        #expect(stack.contains { $0 === host.screen } == false)
    }

    /// ⚠️ THE VIEW MODEL SURVIVES THE REPLACEMENT. The results screen holds it
    /// with a `let`, so it is retained by the screen that stays rather than by
    /// the one that goes — which is what lets a refine screen built later share
    /// the same history, sort and scope.
    @Test func theAnswerKeepsItsViewModelAfterTheSearchScreenLeaves() async {
        let host = Host()
        await host.showResults("haddad")
        host.viewModel.setSortOrder(.recency)
        #expect(host.filterGroups.first?.selectedID == SearchSortOrder.recency.rawValue)
    }

    /// `[ field ][ Cancel ]` — the inbox's searching bar, and the relationship
    /// lists', on a screen that is pushed rather than morphed.
    @Test func refineModeWearsTheInboxSearchingBar() {
        let host = Host()
        let refine = SearchViewController(
            viewModel: host.viewModel,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .refine
        )
        refine.loadViewIfNeeded()
        #expect(refine.navigationItem.hidesBackButton)
        #expect(refine.navigationItem.rightBarButtonItems?.map(\.title) == ["Cancel"])
        #expect(refine.navigationItem.titleView is UITextField)
    }

    /// It exists to change an answer that already exists, so starting empty
    /// would make "adjust one word" mean "type the whole thing again".
    @Test func refineModeOpensCarryingTheQuery() async {
        let host = Host()
        await host.showResults("haddad")
        let refine = SearchViewController(
            viewModel: host.viewModel,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .refine
        )
        refine.loadViewIfNeeded()
        #expect((refine.navigationItem.titleView as? UITextField)?.text == "haddad")
    }

    /// ⚠️ ONE VIEW MODEL, TWO SCREENS, AND ONE CALLBACK SLOT. A refine screen
    /// pushed over the answer takes `onPhaseChange` in its own `viewDidLoad`
    /// and never hands it back. Without the results screen re-subscribing on
    /// the way back in, its Users tab keeps the OLD answer while its post tabs
    /// — driven by a different callback — show the new one.
    @Test func theAnswerHearsAgainAfterARefineScreenHasBeenOverIt() async {
        let host = Host()
        await host.showResults("haddad")
        await host.settleAnswer()
        let results = try? #require(host.results)
        #expect(results?.peoplePageForTesting.rowCountForTesting == 1)

        // A refine screen loads and takes the callback.
        let refine = SearchViewController(
            viewModel: host.viewModel,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .refine
        )
        refine.loadViewIfNeeded()

        // Coming back re-claims it...
        results?.beginAppearanceTransition(true, animated: false)
        results?.endAppearanceTransition()

        // ...so a phase published now reaches the Users tab.
        host.viewModel.queryChanged("")
        #expect(results?.peoplePageForTesting.displayedHandlesForTesting == ["@haddad"],
                "explore does not touch the answer")

        // ⚠️ COUNTED, THIS PROVED NOTHING. The stub answers every query with
        // exactly one person, so "still 1 row" is the same assertion before and
        // after — it passed whether or not the tab had heard anything. The
        // handle is what distinguishes the new answer from the old one, and the
        // results header used to be where a test could read it.
        host.viewModel.submitQuery("nobody")
        await host.settleAnswer(showing: "@nobody")
        #expect(results?.peoplePageForTesting.displayedHandlesForTesting == ["@nobody"])
    }

    /// ⚠️ CANCEL PUTS THE ANSWER BACK. Typing on the refine screen drives the
    /// SHARED view model to `.suggesting` — right for the screen being typed
    /// in, wrong for the answer underneath, whose whole content is an answer.
    @Test func cancellingARefineRestoresTheAnswerUnderneath() async {
        let host = Host()
        await host.showResults("haddad")
        await host.settleAnswer()
        guard case .results = host.viewModel.currentPhase else {
            Issue.record("expected an answer to start from")
            return
        }

        host.viewModel.queryChanged("haddadx")
        guard case .suggesting = host.viewModel.currentPhase else {
            Issue.record("typing should have moved the phase to the typeahead")
            return
        }

        host.viewModel.restoreSubmittedAnswer()
        guard case .results = host.viewModel.currentPhase else {
            Issue.record("cancel should have put the answer back")
            return
        }
    }

    /// ⚠️ A REFINE SCREEN MUST NOT RESET THE SHARED PHASE. `showExplore()` in
    /// `viewDidLoad` would cancel the answer's in-flight search and drive the
    /// phase to `.explore`, which the results screen maps to a spinner — so a
    /// post answer landing while refine is up would flip its Posts tab back to
    /// loading.
    @Test func buildingARefineScreenLeavesTheAnswerAlone() async {
        let host = Host()
        await host.showResults("haddad")
        await host.settleAnswer()

        let refine = SearchViewController(
            viewModel: host.viewModel,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .refine
        )
        refine.loadViewIfNeeded()

        // The phase is the typeahead for the query being edited, never
        // `.explore` — which is what `showExplore()` would have made it.
        switch host.viewModel.currentPhase {
        case .suggesting, .results:
            break
        default:
            Issue.record("a refine screen reset the shared phase")
        }
    }

    // MARK: - The query on the results screen is a door

    /// ⚠️ NO KEYBOARD IS EVER SUMMONED HERE, and now that is structural rather
    /// than refused. The door used to be a `UISearchTextField` that said no in
    /// `textFieldShouldBeginEditing`; it is a glyph, so there is no responder
    /// to become. What is still worth pinning is that the tap ASKS — a door
    /// that leads nowhere is indistinguishable from a screen that has stopped
    /// responding.
    @Test func theResultsQueryDoorAsksToGoBack() async {
        let host = Host()
        await host.showResults("haddad")
        let results = host.results
        var asked = 0
        results?.onEditQuery = { asked += 1 }

        let door = try? #require(results?.navigationItem.rightBarButtonItems?.first)
        #expect(door?.customView == nil)
        _ = door?.target?.perform(door?.action, with: door)
        #expect(asked == 1)
    }

    /// ⚠️ **A GLYPH, NOT A FIELD, AND THE WIDTH IS THE REASON.** Measured with
    /// `-leading-room` on a 402pt bar: 120pt of fixed costs leaves 282 to
    /// share, and a selector and a field each taking half paves the bar EXACTLY
    /// — no margin at all. A pop briefly narrows the bar, and UIKit's one
    /// answer to items that will not fit is to sweep the group into a `•••`.
    /// A 44pt glyph leaves the selector 141pt of ceiling and ~100pt of slack.
    @Test func theQueryDoorIsAGlyphAndNotACustomView() async {
        let host = Host()
        await host.showResults("haddad")
        let items = host.results?.navigationItem.rightBarButtonItems

        #expect(items?.count == 1)
        // No custom view means no width of its own to negotiate: UIKit sizes it
        // at the platter, the same as For You's search glyph.
        #expect(items?.first?.customView == nil)
        #expect(items?.compactMap { $0.customView as? UITextField }.isEmpty == true)
    }

    /// ⚠️ REAL BAR ITEMS, NOT A COMPOSITE TITLE VIEW. A title view is one view
    /// to UIKit: a push snapshots it and cross-fades the picture, so the glass
    /// bubbles cannot interpolate into the destination's. Items do.
    @Test func theHeaderIsBuiltFromBarItems() async {
        let host = Host()
        await host.showResults("haddad")
        let results = host.results

        // The query door is a trailing item...
        #expect(results?.navigationItem.rightBarButtonItems?.count == 1)
        // ...and the selector SUPPLEMENTS the back button rather than replacing
        // it, which is what keeps the interactive pop alive — `NativePopPolicy`
        // refuses the edge gesture for a custom leading item without this, and
        // refuses it outright for a hidden back button.
        #expect(results?.navigationItem.leftItemsSupplementBackButton == true)
        #expect(results?.navigationItem.hidesBackButton == false)
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
