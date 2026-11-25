import Testing
import UIKit
@testable import CoreNavigation

/// The "+" in Explore's top bar (#2489): just inboard of search, a menu
/// whose rows open their destination, and a guest's Sign in in its place —
/// the same item, re-dressed in place.
@MainActor
struct CreateBarItemTests {
    private final class Spy {
        var opened: [CreateDestination] = []
        var signIns = 0
    }

    private func make(channels: Bool = false) -> (CreateBarItem, Spy) {
        let spy = Spy()
        let item = CreateBarItem(
            destinations: CreateDestination.offered(channels: channels),
            open: { spy.opened.append($0) },
            signIn: { spy.signIns += 1 }
        )
        return (item, spy)
    }

    /// Runs `action` as a tap would: through a control's primary action.
    private func fire(_ action: UIAction) {
        let control = UIButton(type: .system)
        control.addAction(action, for: .primaryActionTriggered)
        control.sendActions(for: .primaryActionTriggered)
    }

    private func makeSearch() -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(), primaryAction: UIAction { _ in })
        item.identifier = "foryou.search"
        return item
    }

    @Test func theMenuOffersThePostWaysWithoutTheChannels() {
        #expect(CreateDestination.offered(channels: false) == [.camera, .upload, .text])
        #expect(CreateDestination.offered(channels: true) == [.camera, .upload, .text, .channel])
    }

    /// A member: the "+" with its menu, one row per destination, in order.
    @Test func aMembersItemIsThePlusWithItsMenu() {
        let (create, _) = make()
        create.showSignIn(false)
        #expect(create.item.identifier == CreateBarItem.identifier)
        #expect(create.item.accessibilityLabel == "Create")
        #expect(create.item.primaryAction == nil)
        #expect(create.item.style == .plain)
        let titles = create.item.menu?.children.map(\.title)
        #expect(titles == ["Camera", "Upload Media", "Text Post"])
    }

    @Test func eachRowOpensItsOwnDestination() {
        let (create, spy) = make(channels: true)
        let rows = create.item.menu?.children.compactMap { $0 as? UIAction } ?? []
        #expect(rows.count == 4)
        rows.forEach(fire)
        #expect(spy.opened == [.camera, .upload, .text, .channel])
        #expect(spy.signIns == 0)
    }

    @Test func newChannelIsOfferedOnlyWithTheChannels() {
        let (withoutChannels, _) = make(channels: false)
        let (withChannels, _) = make(channels: true)
        #expect(withoutChannels.item.menu?.children.contains { $0.title == "New Channel" } == false)
        #expect(withChannels.item.menu?.children.last?.title == "New Channel")
    }

    /// `[0]` is the screen edge: search there, the "+" just inboard.
    @Test func theItemStandsJustBeforeSearch() {
        let (create, _) = make()
        let search = makeSearch()
        let group = create.trailingGroup(search: search)
        #expect(group.count == 2)
        #expect(group.first === search)
        #expect(group.last === create.item)
    }

    /// A guest: Sign in in the "+"'s place, prominent, one tap to the sheet
    /// — no menu of things they cannot do yet.
    @Test func aGuestsItemIsSignIn() throws {
        let (create, spy) = make()
        create.showSignIn(true)
        #expect(create.isSignIn)
        #expect(create.item.accessibilityLabel == "Sign in")
        #expect(create.item.style == .prominent)
        #expect(create.item.menu == nil)
        #expect(create.item.image != nil)
        fire(try #require(create.item.primaryAction))
        #expect(spy.signIns == 1)
        #expect(spy.opened.isEmpty)
    }

    /// Signing in and out re-dresses the SAME instance (R3): the trailing
    /// group's list does not change, so the bar redraws this item alone.
    @Test func signingInAndOutKeepsTheInstance() {
        let (create, _) = make()
        let item = create.item
        create.showSignIn(true)
        #expect(create.item === item)
        create.showSignIn(false)
        #expect(create.item === item)
        #expect(create.item.menu?.children.count == 3)
        #expect(create.item.primaryAction == nil)
        #expect(create.item.style == .plain)
        #expect(create.item.accessibilityLabel == "Create")
        #expect(create.item.image != nil)
    }
}
