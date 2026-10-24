import Testing
import UIKit
@testable import DesignSystem

/// The bar contract's factory (#1679): every item it makes carries its
/// identifier, an icon is a stock image item, a wide word is a plain view
/// whose bubble the bar draws.
@MainActor
struct BarItemsTests {
    @Test func anIconIsAStockImageItemWithItsIdentity() {
        var tapped = 0
        let item = BarItems.icon(id: "test.share", image: UIImage(systemName: "square.and.arrow.up"), label: "Share") {
            tapped += 1
        }
        #expect(item.identifier == "test.share")
        #expect(item.customView == nil, "an icon in a custom view")
        #expect(item.image != nil)
        #expect(item.accessibilityLabel == "Share")
        #expect(item.primaryAction?.image == nil, "the action carries an image it would re-apply on fire")
        item.primaryAction?.performWithSender(nil, target: nil)
        #expect(tapped == 1)
    }

    @Test func anIconWithAMenuOpensIt() {
        let menu = UIMenu(children: [UIAction(title: "Report") { _ in }])
        let item = BarItems.icon(id: "test.more", image: UIImage(systemName: "ellipsis"), label: "More", menu: menu)
        #expect(item.identifier == "test.more")
        // The item keeps a copy of the menu.
        #expect(item.menu?.children.map(\.title) == ["Report"])
        #expect(item.customView == nil)
    }

    @Test func aTitleIsProminentOnlyWhenAsked() {
        let plain = BarItems.title(id: "test.message", title: "Message") {}
        let primary = BarItems.title(id: "test.follow", title: "Follow", prominent: true) {}
        #expect(plain.style == .plain)
        #expect(primary.style == .prominent)
        #expect(primary.identifier == "test.follow")
    }

    /// R5: the wide item's bubble is the BAR's — no glass of its own — and
    /// its prominence is the bar's `.prominent`.
    @Test func aStretchedItemLetsTheBarDrawItsBubble() {
        var tapped = 0
        let made = BarItems.stretched(id: "test.follow", title: "Follow", prominent: true) { tapped += 1 }
        #expect(made.item.identifier == "test.follow")
        #expect(made.item.customView === made.label)
        #expect(!made.item.hidesSharedBackground, "the wide item draws a glass of its own")
        #expect(made.item.style == .prominent)
        #expect(!(made.item.customView is UIControl), "a control in the bar item")
        #expect(made.label.title == "Follow")
        #expect(made.label.accessibilityTraits.contains(.button))
        #expect(made.label.accessibilityActivate())
        made.label.debugTap()
        #expect(tapped == 2)
    }

    /// A glyph may lead the word; off, the tap does nothing and VoiceOver
    /// hears it as disabled.
    @Test func aStretchedItemTakesAGlyphAndAnOffState() {
        var tapped = 0
        let made = BarItems.stretched(id: "test.mute", title: "Mute", image: UIImage(systemName: "bell.slash")) {
            tapped += 1
        }
        #expect(made.label.image != nil)
        #expect(made.item.style == .plain)
        #expect(made.label.accessibilityLabel == "Mute")
        made.label.isEnabled = false
        made.label.debugTap()
        #expect(!made.label.accessibilityActivate())
        #expect(tapped == 0, "a disabled item answered")
        #expect(made.label.accessibilityTraits.contains(.notEnabled))
        made.label.isEnabled = true
        made.label.debugTap()
        #expect(tapped == 1)
        #expect(!made.label.accessibilityTraits.contains(.notEnabled))
    }

    @Test func aContainerKeepsItsViewAndIdentity() {
        let view = UIView()
        let item = BarItems.container(id: BarItems.SharedID.walletBalance, view: view)
        #expect(item.customView === view)
        #expect(item.identifier == "shell.wallet-balance")
    }
}
