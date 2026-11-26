import CoreModels
import CoreNavigation
import DesignSystem
import EntityStore
import MediaCore
import MediaUI
import PostGrid
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
/// - the Follow beside the flat rows' "…" (#2419, the badge passive since):
///   `SnapAuthorFollowStore.follow` behind the member gate — optimistic flip,
///   `.toggleOn`, failure put back and said — and Requested's withdrawal.
///
/// One per composition root (`FeedFeatureBuilder`), shared by the surfaces
/// it builds.
@MainActor
final public class PostAuthorMarks {
    public let store: SnapAuthorFollowStore
    let binding: AuthorBadgeBinding
    /// Follows from every other surface (a profile's Follow), heard here.
    private var followSubscription: FollowGraphSubscription?

    public init(
        writer: (any SocialGraphWriting)?, reader: (any SocialGraphReading)?, entities: any ProfileEntityReading & ProfileEntityWriting,
        followEvents: FollowGraphEvents? = nil,
        viewer: @escaping @MainActor () -> ProfileID?
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
    /// with no author). `offersFollow`: the face's host draws the author's
    /// Follow too (the flat rows, #2419); a shelf's card is told none.
    public func bind(_ face: any AuthorBadgeDrawing, to author: ProfileID?, offersFollow: Bool = false) {
        binding.bind(face, to: author, offersFollow: offersFollow)
    }

    /// The Follow for `author` as known now — for a still copy of a bound
    /// band (the reveal's stand-in).
    public func followOffer(for author: ProfileID?) -> AuthorFollowOffer {
        store.followOffer(for: author)
    }

    /// The mark for `author` as known now — for a still copy of a bound face
    /// (a preview, a stand-in).
    public func badge(for author: ProfileID?) -> PersonPill.Badge {
        store.badge(for: author)
    }

    /// Follow (#2419): follows `author` — the member gate first (a guest's
    /// sign-in prompt), then the store's optimistic follow and the follow
    /// haptic; a refusal puts Follow back and says so from the screen
    /// `source` is on.
    public func follow(_ author: ProfileID, handle: String?, name: String?, from source: UIResponder) {
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

    /// Requested's "Cancel Request" (#2419): withdraws the pending request
    /// to `author`, optimistically; a refusal puts Requested back and says so.
    public func cancelRequest(to author: ProfileID, handle: String?, from source: UIResponder) {
        store.cancelRequest(to: author) { [weak source] in
            guard let screen = source?.firstController(as: UIViewController.self) else { return }
            let who = handle.map { $0.isEmpty ? "" : " to @" + $0 } ?? ""
            Feedback.failure("Couldn't cancel your request" + who, from: screen)
        }
    }
}
