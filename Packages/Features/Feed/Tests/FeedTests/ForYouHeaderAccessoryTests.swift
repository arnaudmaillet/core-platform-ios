import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// **The header's injected trailing item — the wallet badge, from out here.**
///
/// The balance already stands in the Maps header and on the post screen. It is
/// the same number in all three places, so the screens do not each learn what a
/// wallet is: the shell builds ONE item and hands it over, and this screen only
/// promises to keep it in its trailing run.
///
/// That promise is the thing worth testing, because the run is rebuilt: the
/// screen writes its own items at load, and an item installed from outside has
/// to survive that write and every later one.
@MainActor
struct ForYouHeaderAccessoryTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func screen() -> ForYouViewController {
        ForYouViewController(
            viewModel: ForYouViewModel(
                repository: StubHeaderProvider()
            ),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeSnapFeed: { _ in UIViewController() },
            prewarm: { _ in }
        )
    }

    private func accessory() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: UIView())
        item.accessibilityLabel = "Balance"
        return item
    }

    /// With nothing injected the header is what it always was: one trailing
    /// item, the lens menu.
    @Test func theHeaderKeepsItsOwnItemWhenNothingIsInjected() {
        let screen = screen()
        screen.loadViewIfNeeded()

        #expect(screen.navigationItem.rightBarButtonItems?.count == 1)
    }

    /// ⚠️ THE BADGE STANDS INBOARD OF THE SCREEN'S OWN ITEM.
    ///
    /// `rightBarButtonItems[0]` is the one nearest the screen edge, so the
    /// lens menu keeps the corner and the balance sits to its left — the
    /// arrangement the Maps header already wears ([coin] [bell]).
    @Test func theInjectedBadgeStandsInboardOfTheLensMenu() throws {
        let screen = screen()
        screen.loadViewIfNeeded()
        let badge = accessory()

        screen.setTrailingAccessoryItem(badge)

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.count == 2)
        #expect(items.last === badge, "the balance took the corner from the lens menu")
    }

    /// ⚠️ AND IT SURVIVES THE SCREEN'S OWN WRITE.
    ///
    /// The item can only be handed over once the screen exists, and the screen
    /// writes its trailing run at `viewDidLoad` — so an injection that happened
    /// first must not be erased by it. Ordered the awkward way round on
    /// purpose: injected BEFORE the view loads.
    @Test func anItemInjectedBeforeTheViewLoadsSurvives() throws {
        let screen = screen()
        let badge = accessory()

        screen.setTrailingAccessoryItem(badge)
        screen.loadViewIfNeeded()

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.contains { $0 === badge }, "the header's own write erased the badge")
    }

    /// Replacing it swaps the item rather than adding a second one — the badge
    /// hands over a FRESH `UIBarButtonItem` whenever its count changes width,
    /// because a bar measures a custom view once, at install.
    @Test func replacingTheItemLeavesOneOfIt() throws {
        let screen = screen()
        screen.loadViewIfNeeded()

        screen.setTrailingAccessoryItem(accessory())
        let second = accessory()
        screen.setTrailingAccessoryItem(second)

        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.count == 2)
        #expect(items.last === second)
    }

    /// And clearing it puts the header back exactly as it was.
    @Test func clearingItRestoresTheHeader() throws {
        let screen = screen()
        screen.loadViewIfNeeded()

        screen.setTrailingAccessoryItem(accessory())
        screen.setTrailingAccessoryItem(nil)

        #expect(screen.navigationItem.rightBarButtonItems?.count == 1)
    }

    // MARK: - The leading item (the shell's bell)

    /// ⚠️ THE BELL TAKES THE LEADING CORNER, and the lens stands inboard of it.
    ///
    /// `leftBarButtonItems[0]` is the item nearest the LEADING screen edge, so
    /// the header reads `[bell][lens] … [coins][search]`.
    @Test func theInjectedBellLeadsAheadOfTheLens() throws {
        let screen = screen()
        screen.loadViewIfNeeded()
        let bell = accessory()

        screen.setLeadingAccessoryItem(bell)

        let items = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(items.count == 2)
        #expect(items.first === bell, "the lens took the corner from the bell")
    }

    /// Injected before the view loads — the order the shell actually uses —
    /// it survives the screen's own write of the leading group at load.
    @Test func aBellInjectedBeforeTheViewLoadsSurvives() throws {
        let screen = screen()
        let bell = accessory()

        screen.setLeadingAccessoryItem(bell)
        screen.loadViewIfNeeded()

        let items = try #require(screen.navigationItem.leftBarButtonItems)
        #expect(items.first === bell, "the header's own write erased the bell")
    }

    /// Clearing it leaves the lens alone in the leading group.
    @Test func clearingTheBellLeavesTheLens() {
        let screen = screen()
        screen.loadViewIfNeeded()

        screen.setLeadingAccessoryItem(accessory())
        screen.setLeadingAccessoryItem(nil)

        #expect(screen.navigationItem.leftBarButtonItems?.count == 1)
    }
}

private final class StubHeaderProvider: ForYouProviding, @unchecked Sendable {
    func firstPage() async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
    func page(after token: String) async throws -> ForYouPage {
        ForYouPage(posts: [], nextPageToken: nil)
    }
}
