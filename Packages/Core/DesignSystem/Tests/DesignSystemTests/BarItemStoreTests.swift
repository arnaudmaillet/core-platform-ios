import Testing
import UIKit
@testable import DesignSystem

/// THE BAR KEEPS WHAT STAYS (#2331): an item that stays is the same
/// instance, a state change is made in place, and the bar is handed a group
/// only when its list changes.
@MainActor
struct BarItemStoreTests {
    private func icon(_ id: String) -> UIBarButtonItem {
        BarItems.icon(id: id, image: UIImage(systemName: "qrcode"), label: id) {}
    }

    @Test func anItemThatStaysIsTheSameInstance() {
        let store = BarItemStore()
        var made = 0
        let first = store.item("test.qr") { made += 1; return icon("test.qr") }
        let again = store.item("test.qr") { made += 1; return icon("test.qr") }
        #expect(first === again, "a rebuild minted the item anew")
        #expect(made == 1)
        #expect(first.identifier == "test.qr")
    }

    @Test func updateDressesTheItemOnEveryPassAndOnTheFirst() throws {
        let store = BarItemStore()
        var title = "Follow"
        func pass() -> UIBarButtonItem {
            store.item("test.follow") {
                BarItems.stretched(id: "test.follow", title: "", prominent: true) {}.item
            } update: { item in
                BarItems.update(stretched: item, title: title, prominent: title == "Follow")
            }
        }
        let item = pass()
        let label = try #require(item.customView as? StretchedBarLabel)
        #expect(label.title == "Follow")
        #expect(item.style == .prominent)
        title = "Requested"
        #expect(pass() === item)
        #expect(label.title == "Requested")
        #expect(label.ink == .label)
        #expect(item.style == .plain)
    }

    @Test func anItemThatLeavesIsDroppedAndComesBackNew() {
        let store = BarItemStore()
        let controller = UIViewController()
        let follow = store.item("test.follow") { icon("test.follow") }
        let message = store.item("test.message") { icon("test.message") }
        store.apply(toolbar: [follow, store.separator(before: "test.message"), message], to: controller, animated: false)

        let bell = store.item("test.bell") { icon("test.bell") }
        let keptMessage = store.item("test.message") { icon("test.message") }
        #expect(keptMessage === message)
        store.apply(toolbar: [bell, store.separator(before: "test.message"), keptMessage], to: controller, animated: false)
        #expect(store.debugKeptIdentifiers == ["test.bell", "test.message"], "Follow was kept after it left")

        let back = store.item("test.follow") { icon("test.follow") }
        #expect(back !== follow, "an item that left came back as the old instance")
    }

    @Test func aSeparatorStaysWithTheItemItStandsBefore() {
        let store = BarItemStore()
        let controller = UIViewController()
        let separator = store.separator(before: "test.message")
        #expect(store.separator(before: "test.message") === separator)
        let message = store.item("test.message") { icon("test.message") }
        store.apply(toolbar: [separator, message], to: controller, animated: false)
        #expect(store.separator(before: "test.message") === separator)
        store.apply(toolbar: [message], to: controller, animated: false)
        #expect(store.separator(before: "test.message") !== separator, "a separator outlived its place")
    }

    @Test func theBarIsHandedAGroupOnlyWhenItsListChanges() {
        let store = BarItemStore()
        let controller = UIViewController()
        let navigationItem = controller.navigationItem
        func toolbar(_ ids: [String]) -> [UIBarButtonItem] {
            ids.map { id in store.item(id) { icon(id) } }
        }
        #expect(store.apply(toolbar: toolbar(["a", "b"]), to: controller, animated: false))
        #expect(!store.apply(toolbar: toolbar(["a", "b"]), to: controller, animated: false), "the same list handed again")
        #expect(store.apply(toolbar: toolbar(["b", "a"]), to: controller, animated: false), "a new order was not handed")
        #expect(store.apply(toolbar: toolbar(["b"]), to: controller, animated: false))
        #expect(store.debugWrites == 3)
        #expect(controller.toolbarItems?.map(\.identifier) == ["b"])

        let leading = BarItemStore()
        let more = leading.item("test.more") { icon("test.more") }
        #expect(!leading.apply(leading: [], to: navigationItem, animated: false), "nothing on a bar holding nothing")
        #expect(leading.apply(leading: [more], to: navigationItem, animated: false))
        #expect(!leading.apply(leading: [more], to: navigationItem, animated: false))
        #expect(navigationItem.leftBarButtonItems?.first === more)

        let trailing = BarItemStore()
        let close = trailing.item("test.close") { icon("test.close") }
        #expect(trailing.apply(trailing: [close], to: controller, animated: false))
        #expect(!trailing.apply(trailing: [close], to: controller, animated: false))
        #expect(trailing.apply(trailing: [], to: controller, animated: false))
        #expect(controller.ownTrailingBarItems.isEmpty)
    }

    /// A `variant` re-mints the item under its identifier — what cannot
    /// change in place (a title item's word, which the bar measures once).
    @Test func aNewVariantIsANewItemUnderTheSameIdentifier() {
        let store = BarItemStore()
        let short = store.item("test.timer", variant: "7 h") { icon("test.timer") }
        #expect(store.item("test.timer", variant: "7 h") { icon("test.timer") } === short)
        let long = store.item("test.timer", variant: "12 h") { icon("test.timer") }
        #expect(long !== short)
        #expect(long.identifier == short.identifier)
    }

    /// A kept stretched item turns in place (#2331): its word, its glyph,
    /// its loader and its stretch.
    @Test func aStretchedLabelChangesInPlace() {
        let made = BarItems.stretched(id: "test.mute", title: "Mute", image: UIImage(systemName: "bell.slash")) {}
        let label = made.label
        #expect(label.stretches)
        #expect(label.contentHuggingPriority(for: .horizontal) == .init(1))
        label.title = "Unmute"
        #expect(label.title == "Unmute")
        #expect(label.accessibilityLabel == "Unmute")
        let bell = UIImage(systemName: "bell")
        label.image = bell
        #expect(label.image === bell)

        label.isBusy = true
        #expect(label.accessibilityTraits.contains(.notEnabled))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        window.addSubview(label)
        window.isHidden = false
        #expect(label.debugIsLoading, "the loader does not turn")
        label.isBusy = false
        #expect(!label.debugIsLoading)
        #expect(!label.accessibilityTraits.contains(.notEnabled))

        label.stretches = false
        #expect(label.contentHuggingPriority(for: .horizontal) == .required, "a label that stopped stretching")
        label.stretches = true
        #expect(label.contentHuggingPriority(for: .horizontal) == .init(1))
        label.removeFromSuperview()
    }
}
