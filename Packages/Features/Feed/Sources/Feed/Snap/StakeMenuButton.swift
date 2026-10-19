import CoreNavigation
import UIKit

/// A like control whose long press raises the stake menu (`StakeMenu`) — the
/// rail's heart and the comments bar's — for a MEMBER only (#1146).
///
/// A guest gets no menu: no amounts, and no door into the Shop (the empty
/// pack's row). The question is asked when the press lands, from the button
/// itself up the responder chain (`MemberGates`), so a viewer who signs up
/// mid-session has the menu on their next press, with nothing to re-install.
/// Their tap still runs the control's action, which asks them to sign up.
class StakeMenuButton: UIButton {
    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !MemberGates.isGuest(self) else { return nil }
        return super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
    }
}
