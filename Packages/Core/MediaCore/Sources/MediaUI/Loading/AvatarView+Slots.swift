import DesignSystem
import MediaCore
import UIKit

/// DesignSystem's people rows lay a disc out but cannot load a picture; they
/// take the app's avatar through `AvatarSlotView` (#1750).
extension AvatarView: AvatarSlotView {}

/// The face with its relation mark in the same slot (#2411): the "New
/// message" sheet's people rows wear the mark the inbox rows wear (#2049).
/// A recycled row goes back to a bare face, no mark, until its host says
/// where the viewer stands with the next person.
extension RelationMarkedAvatarView: AvatarSlotView {
    public func reset() {
        avatar.reset()
        setMark(.none, animated: false)
    }
}

public extension PersonListCell {
    /// The row's avatar: the picture with its skeleton, the initials without
    /// one (the avatar contract). Made on first use and kept for the cell's
    /// life; `configure(with:)` sets its initials, `setPicture` its face.
    /// A row wearing the relation mark (`markedAvatar`) answers with the
    /// face under the mark.
    var avatar: AvatarView {
        if let avatar = avatarSlot as? AvatarView { return avatar }
        if let marked = avatarSlot as? RelationMarkedAvatarView { return marked.avatar }
        let avatar = AvatarView(diameter: MonogramAvatarView.rowDiameter, size: .avatar)
        avatarSlot = avatar
        return avatar
    }

    /// The row's face wearing the relation mark (#2049, #2411): the app's
    /// one marked face (`RelationMarkedAvatarView`) in the row's disc. A
    /// host that shows where the viewer stands with each person asks for
    /// this before `avatar`, and keeps asking for it: the slot holds one
    /// kind of face for the cell's life.
    var markedAvatar: RelationMarkedAvatarView {
        if let marked = avatarSlot as? RelationMarkedAvatarView { return marked }
        let marked = RelationMarkedAvatarView(diameter: MonogramAvatarView.rowDiameter, size: .avatar)
        avatarSlot = marked
        return marked
    }
}
