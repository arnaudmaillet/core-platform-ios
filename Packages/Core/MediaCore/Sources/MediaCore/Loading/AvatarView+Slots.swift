import DesignSystem
import UIKit

/// DesignSystem's people rows lay a disc out but cannot load a picture; they
/// take the app's avatar through `AvatarSlotView` (#1750).
extension AvatarView: AvatarSlotView {}

public extension PersonListCell {
    /// The row's avatar: the picture with its skeleton, the initials without
    /// one (the avatar contract). Made on first use and kept for the cell's
    /// life; `configure(with:)` sets its initials, `setPicture` its face.
    var avatar: AvatarView {
        if let avatar = avatarSlot as? AvatarView { return avatar }
        let avatar = AvatarView(diameter: MonogramAvatarView.rowDiameter, size: .avatar)
        avatarSlot = avatar
        return avatar
    }
}
