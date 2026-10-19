import CoreModels
import CoreNavigation
import Testing
import UIKit
@testable import Feed

/// The rail's and the comments bar's like raise the stake menu for a member
/// only (#1146).
@MainActor
struct StakeMenuButtonTests {
    private final class GateHolder: UIViewController, MemberGateProviding {
        let memberGate: any MemberGating
        init(member: Bool) {
            memberGate = MemberGate(isMember: member)
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    /// The button, and the holder that must outlive it (a view does not
    /// keep its superview's controller alive).
    private func button(member: Bool?) -> (StakeMenuButton, GateHolder?) {
        let button = StakeMenuButton(configuration: .plain())
        button.menu = UIMenu(title: "Stake", children: [UIAction(title: "Stake 10") { _ in }])
        let holder = member.map { GateHolder(member: $0) }
        holder?.view.addSubview(button)
        return (button, holder)
    }

    private func raises(_ button: StakeMenuButton) throws -> Bool {
        let interaction = try #require(button.contextMenuInteraction)
        return button.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero) != nil
    }

    @Test func aGuestGetsNoMenu() throws {
        let (guest, holder) = button(member: false)
        #expect(try !raises(guest), "a guest's like raised the stake menu")
        withExtendedLifetime(holder) {}
    }

    @Test func aMemberGetsTheMenu() throws {
        let (member, holder) = button(member: true)
        #expect(try raises(member))
        withExtendedLifetime(holder) {}
    }

    /// Outside the shell (no gate up the chain) nothing is gated.
    @Test func withNoGateTheMenuStands() throws {
        let (loose, _) = button(member: nil)
        #expect(try raises(loose))
    }
}
