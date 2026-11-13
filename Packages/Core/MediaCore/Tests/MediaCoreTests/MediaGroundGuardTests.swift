import DesignSystem
import Foundation
import Testing
import UIKit
@testable import MediaCore

/// ONE MEDIA GROUND (#1771): a media slot's host paints nothing under its
/// bone but `Surface.mediaGround` (or its on-dark variant), so a picture
/// that is loading, missing or failed wears one grey — the bone's own — and
/// two greys never meet. The owner's question (2026-10-27): a host keeping
/// its own fill under a grey skeleton made a double ground, and a failed
/// picture showed a colour the loading one never had.
///
/// Its scan half is a repository guard in `RepoGuards` (#2371), which every pull request runs.
@MainActor
struct MediaGroundGuardTests {
    @Test func theMediaGroundIsTheBonesGrey() {
        #expect(Surface.mediaGround == Surface.skeleton)
        #expect(Surface.mediaGroundOnDark == Surface.skeletonOnDark)
        #expect(SkeletonBoneView().fill == Surface.mediaGround)
    }

    /// A face that never arrives sits on its bone's grey: the initials'
    /// plate and the avatar's bone are the avatar's ground — fixed light, not
    /// the media ground, which follows the appearance (#2051).
    @Test func anAvatarsPlateIsItsBonesGround() throws {
        let avatar = AvatarView(diameter: 40, size: .avatar)
        let plate = try #require(avatar.monogram.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        #expect(plate.fillColor == Surface.avatarGround.cgColor)
        avatar.skeleton.layoutIfNeeded()
        #expect(avatar.skeleton.drawnGround == Surface.avatarGround.cgColor)
    }
}
