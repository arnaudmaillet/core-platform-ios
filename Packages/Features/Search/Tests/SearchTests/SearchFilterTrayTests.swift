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
            window.rootViewController = UINavigationController(rootViewController: screen)
            window.makeKeyAndVisible()
            screen.loadViewIfNeeded()
            window.layoutIfNeeded()
        }

        var field: UITextField? { screen.navigationItem.titleView as? UITextField }
        var item: UIBarButtonItem? { screen.navigationItem.rightBarButtonItems?.first }

        /// The tray's contents. Readable because the menu is rebuilt when the
        /// order changes rather than deferred to the moment it opens —
        /// `UIDeferredMenuElement`'s provider is not public, so a deferred tray
        /// could only be checked by opening it on a device.
        var trayActions: [UIAction] {
            (item?.menu?.children ?? []).flatMap { element -> [UIAction] in
                (element as? UIMenu)?.children.compactMap { $0 as? UIAction } ?? []
            }
        }

        func submit(_ text: String) {
            viewModel.onQueryTextChange?(text)
            _ = screen.textFieldShouldReturn(field ?? UITextField())
        }
    }

    // MARK: - The tray

    @Test func theTrailingSlotOpensAMenuRatherThanSubmitting() {
        let host = Host()
        #expect(host.item?.menu != nil)
        // A submit button had a title and an action; this has neither.
        #expect(host.item?.title == nil)
        #expect(host.item?.action == nil)
    }

    @Test func theTrayOffersTheThreeOrdersTheContractSupports() {
        let titles = Host().trayActions.map(\.title)
        #expect(titles == ["Top matches", "Most recent", "Most popular"])
    }

    /// ⚠️ Not "most liked". `search.v1` documents POPULARITY as reading a
    /// periodically-refreshed signal rather than a live count, so a label
    /// promising an exact ranking by likes would describe something the engine
    /// does not do.
    @Test func popularityIsNotLabelledAsALikeCount() {
        let titles = Host().trayActions.map(\.title)
        #expect(!titles.contains { $0.localizedCaseInsensitiveContains("like") })
    }

    @Test func theCheckmarkStartsOnRelevance() {
        let on = Host().trayActions.filter { $0.state == .on }.map(\.title)
        #expect(on == ["Top matches"])
    }

    @Test func theCheckmarkFollowsTheOrderInEffect() {
        let host = Host()
        host.viewModel.setSortOrder(.recency)
        let on = host.trayActions.filter { $0.state == .on }.map(\.title)
        #expect(on == ["Most recent"])
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
        #expect(await host.box.sorts == [.relevance, .recency])
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

        host.viewModel.setSortOrder(.relevance)
        for _ in 0..<20 { await Task.yield() }
        #expect(await host.box.sorts == [.relevance])
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
