import CoreModels
import CoreStorage
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Search

/// The bar's Search button, and the one thing about it that already shipped
/// broken: a field written PROGRAMMATICALLY left the button dead.
///
/// Everything here goes through public UIKit surface — the item is read off
/// `navigationItem` and fired the way UIKit fires it — so no seam had to be
/// opened in the view controller to test it.
///
/// ⚠️ **THE TYPING PATH IS NOT TESTED HERE, AND IT IS NOT AN OVERSIGHT.**
/// The screen listens for `.editingChanged` on its `UISearchTextField`, and
/// no synthetic event reaches that handler in a unit test. Measured, on a
/// field that is hosted in a key window and IS first responder, with the
/// target confirmed registered (`targets=[SearchViewController]`,
/// `actions=["searchTextChanged"]`):
///
///     sendActions(.editingChanged)      → handler NOT called
///     sendActions(.allEditingEvents)    → handler NOT called
///     sendActions(.valueChanged)        → handler NOT called
///     post(textDidChangeNotification)   → handler NOT called
///     perform(#selector(searchTextChanged)) → handler called
///
/// A viewer's keystroke arrives through UIKit's own text pipeline, which a
/// test process cannot raise. ⚠️ An earlier draft of this file "proved" one of
/// those did work — because the probe fired it AFTER a direct `perform` had
/// already flipped the flag, and read the leftover value. Order the probe, or
/// it lies. Typing is covered on the simulator (`-search-query`), not here.
@MainActor
struct SearchSubmitAffordanceTests {
    private actor StubProvider: SearchProviding {
        func searchProfiles(matching query: String, limit: Int32) async throws -> [ProfileSearchResult] {
            [ProfileSearchResult(id: ProfileID("p1"), handle: query, displayName: query, isVerified: false)]
        }
        func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
    }

    /// The screen in a window, because a bar only lays its items out once it
    /// has somewhere to lay them out.
    @MainActor
    private final class Host {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen: SearchViewController
        let viewModel: SearchViewModel

        init(viewModel: SearchViewModel) {
            self.viewModel = viewModel
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

        /// A query arriving from the view model — the path a tapped recent
        /// search takes, and the one that shipped with a dead button.
        func replayQuery(_ text: String) { viewModel.onQueryTextChange?(text) }
    }

    private func makeHost() -> Host {
        Host(viewModel: SearchViewModel(
            repository: StubProvider(),
            router: nil,
            recentSearches: RecentSearchStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 }
            )
        ))
    }

    @Test func theBarCarriesASearchButton() {
        #expect(makeHost().item?.title == "Search")
    }

    @Test func theButtonIsDeadUntilThereIsSomethingToSearchFor() {
        #expect(makeHost().item?.isEnabled == false)
    }

    /// ⚠️ THE REGRESSION THIS FILE EXISTS FOR. `UITextField` raises no editing
    /// event for a programmatic write, so the view model's replay left a live
    /// query in the field under a button that refused to run it. Caught by a
    /// screenshot, not by the type checker.
    @Test func aQueryPutIntoTheFieldForYouAlsoArmsTheButton() {
        let host = makeHost()
        host.replayQuery("haddad")
        #expect(host.field?.text == "haddad")
        #expect(host.item?.isEnabled == true)
    }

    @Test func whitespaceIsNotSomethingToSearchFor() {
        let host = makeHost()
        host.replayQuery("   ")
        #expect(host.item?.isEnabled == false)
    }

    @Test func aReplayedEmptyQueryPutsTheButtonBackToSleep() {
        let host = makeHost()
        host.replayQuery("haddad")
        host.replayQuery("")
        #expect(host.item?.isEnabled == false)
    }

    /// The button and the keyboard's Search key are one path, so pressing the
    /// button has to reach the view model exactly as Return does.
    @Test func pressingTheButtonRunsTheSearch() async throws {
        let host = makeHost()
        var phases: [SearchViewModel.Phase] = []
        host.viewModel.onPhaseChange = { phases.append($0) }
        host.replayQuery("haddad")

        let item = try #require(host.item)
        _ = try #require(item.target).perform(#require(item.action), with: item)

        // ⚠️ `submitQuery` starts a Task; the phase it publishes lands on a
        // later main-actor turn, so asserting straight after the press reads an
        // empty list and calls a working button broken.
        for _ in 0..<50 where !phases.contains(.loading) { await Task.yield() }
        #expect(phases.contains(.loading))
    }

    /// Pressing it also gets the keyboard out of the way of the answer — the
    /// same thing the Return key does.
    @Test func pressingTheButtonGivesUpTheKeyboard() throws {
        let host = makeHost()
        host.replayQuery("haddad")
        try #require(host.field).becomeFirstResponder()
        #expect(host.field?.isFirstResponder == true)

        let item = try #require(host.item)
        _ = try #require(item.target).perform(#require(item.action), with: item)
        #expect(host.field?.isFirstResponder == false)
    }
}
