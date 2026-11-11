import CoreModels
import CoreNavigation
import DesignSystem
import EntityStore
import MediaCore
import UIKit

/// THE RELATION MARK ON THE LISTS' AUTHOR BANDS (#2300): a text post's author
/// is a list card's band — For You's flat rows (the profile's, the place
/// page's and a post set's are the same page), a shelf's text card, For You's
/// preview — and it wore a bare face while the same post's page, and every
/// media post's author row, wore the badge (the owner's rule of 2026-11-02:
/// one mark, the same on every avatar that carries one).
///
/// PostGrid draws the mark and cannot see the follow, so the band's host
/// binds it from here — the SAME source and rule as a feed page's author
/// row, not a second one:
/// - the relation: `SnapAuthorFollowStore`, over the app's `EntityStore`
///   (#896), so a follow made on one surface is every surface's badge;
/// - the binding: `AuthorBadgeBinding` (#1972) — the face known now on bind,
///   every bound face redrawn on an answer (a card configured off screen
///   included) and on a viewer change;
/// - the "+": `SnapAuthorFollowStore.follow` behind the member gate —
///   optimistic flip, `.toggleOn`, failure put back and said.
///
/// One per composition root (`FeedFeatureBuilder`), shared by the surfaces
/// it builds.
@MainActor
final class PostAuthorMarks {
    let store: SnapAuthorFollowStore
    let binding: AuthorBadgeBinding
    /// Follows from every other surface (a profile's Follow), heard here.
    private var followSubscription: FollowGraphSubscription?

    init(
        writer: (any SocialGraphWriting)?, reader: (any SocialGraphReading)?, entities: EntityStore,
        followEvents: FollowGraphEvents? = nil,
        viewer: @escaping @MainActor () -> ProfileID? = SnapAuthorFollowStore.activeProfile
    ) {
        store = SnapAuthorFollowStore(writer: writer, reader: reader, entities: entities, viewer: viewer)
        binding = AuthorBadgeBinding(store: store)
        store.onRelationChange = { [weak self] author in
            self?.binding.relationDidChange(for: author)
        }
        store.onEveryRelationChange = { [weak self] in
            self?.binding.viewerDidChange()
        }
        followSubscription = followEvents?.subscribeOnMain { [weak self] change in
            self?.store.graphDidChange(change)
        }
    }

    /// Binds `face` to `author` — nil draws no mark (a bare band, a post
    /// with no author).
    func bind(_ face: any AuthorBadgeDrawing, to author: ProfileID?) {
        binding.bind(face, to: author)
    }

    /// The mark for `author` as known now — for a still copy of a bound face
    /// (a preview, a stand-in).
    func badge(for author: ProfileID?) -> PersonPill.Badge {
        store.badge(for: author)
    }

    /// The "+": follows `author` — the member gate first, then the store's
    /// optimistic follow and the follow haptic; a refusal puts the "+" back
    /// and says so from the screen `source` is on.
    func follow(_ author: ProfileID, handle: String?, name: String?, from source: UIResponder) {
        MemberGates.perform(.follow(handle: handle), from: source) { [weak self, weak source] in
            guard let self else { return }
            let followed = store.follow(author) { [weak source] in
                guard let screen = source?.firstController(as: UIViewController.self) else { return }
                Feedback.failure(PlusFollow.failureMessage(handle: handle, name: name), from: screen)
            }
            // Turned on at the optimistic flip (#1885).
            if followed { Haptics.play(.toggleOn) }
        }
    }
}
