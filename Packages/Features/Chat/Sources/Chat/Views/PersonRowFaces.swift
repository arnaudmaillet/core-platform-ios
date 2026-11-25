import CoreModels
import DesignSystem
import MediaCore
import MediaUI
import UIKit

/// The faces of a list's person rows (#1750): the skeleton while profile.v1
/// is asked, then the picture, or the initials when there is none.
///
/// One lookup per cell, keyed by the cell: the same person again (a
/// reconfigure) keeps what is under way, and a recycled cell drops the late
/// answer for the person it showed before. The inbox's search, the group
/// member picker and the "New message" sheet (#2411) draw their people rows
/// with it — the directory and the suggestions carry no picture.
@MainActor
final class PersonRowFaces {
    private let avatars: (any PeerAvatarProviding)?
    private let imagePipeline: ImagePipeline?
    private var lookups: [ObjectIdentifier: (id: ProfileID, task: Task<Void, Never>)] = [:]

    init(avatars: (any PeerAvatarProviding)?, imagePipeline: ImagePipeline?) {
        self.avatars = avatars
        self.imagePipeline = imagePipeline
    }

    /// `id`'s face into `avatar`, the face `cell` shows.
    func lookUp(_ id: ProfileID, into avatar: AvatarView, of cell: UICollectionViewCell) {
        let key = ObjectIdentifier(cell)
        if lookups[key]?.id == id { return }
        lookups[key]?.task.cancel()
        guard let avatars, let imagePipeline else {
            lookups[key] = nil
            avatar.setPicture(nil, pipeline: nil)
            return
        }
        avatar.awaitPicture()
        let task = Task { [weak self, weak avatar] in
            let urls = await avatars.avatarURLs(for: [id])
            guard !Task.isCancelled, let self, let avatar, self.lookups[key]?.id == id else { return }
            avatar.setPicture(urls[id], pipeline: imagePipeline)
        }
        lookups[key] = (id, task)
    }

    /// `id`'s face into a plain person row.
    func lookUp(_ id: ProfileID, into cell: PersonListCell) {
        lookUp(id, into: cell.avatar, of: cell)
    }
}
