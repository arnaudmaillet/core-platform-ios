import CoreModels
import MediaUI
import PostGrid
import PostSurfaces
import UIKit

/// The author pill under `-snap-layout-v2` (#2409): one pill for the screen's
/// life, its Follow beside it, and its stretch to the repost once the viewer
/// follows the author.
extension SnapAuthorBar {
    /// ⚠️ ONE PILL FOR THE SCREEN'S LIFE (#2409): a new post blurs its
    /// content in place (`BarItemContentTransition`), as the attribution did;
    /// the platter never morphs between two posts of the same follow state.
    /// The bar morphs only what changes around it: the Follow coming or
    /// going, the pill stretching. A transition owning the bar sees the new
    /// author drawn in one frame, unseen.
    func showAuthorInPlace(_ model: FeedItemDisplayModel, badge: PersonPill.Badge) {
        let canAnimate = host.view.window != nil && host.canAnimateBarItems
        authorIdentityView.setAuthor(
            model, pipeline: host.imagePipeline, secondLine: secondLine(for: model), animated: canAnimate
        )
        authorIdentityView.setFollowBadge(badge, animated: canAnimate)
    }

    /// The pill's second line under v2: the post's sound while the pill
    /// stands stretched (an author the viewer follows, the viewer), nil for
    /// the handle. A text page keeps the handle.
    func secondLine(for model: FeedItemDisplayModel) -> String? {
        guard host.layoutV2, model.mediaURL != nil else { return nil }
        let author = model.authorID
        // The author whose face is up decides from it (a confirmation may be
        // under way); an arriving one from the store's answer, the one the
        // binding is about to draw.
        let stretched = author == follow.author
            ? follow.stretchesPill
            : SnapToolbarFollow.stretches(
                offer: host.followStore.followOffer(for: author), isViewer: host.followStore.isViewer(author)
            )
        return stretched ? host.pillSoundLine(for: model) : nil
    }

    /// The binding's answer for the bar's pill (#2409): the Follow's face.
    func drawBarAuthorFollow(_ offer: AuthorFollowOffer, animated: Bool) {
        guard host.layoutV2, let author = authorBadges.author(of: barAuthorBadge),
              authorIdentityView.shownAuthor?.authorID == author else { return }
        let media = authorIdentityView.shownAuthor?.mediaURL != nil
        follow.show(offer, for: author, isViewer: media && host.followStore.isViewer(author), seen: animated)
    }

    /// v2's budget for the pill: the footer's room less the repost and the
    /// Follow beside it; nil off v2 or before the bar is measured.
    func v2PillBudget() -> CGFloat? {
        guard host.layoutV2, let room = toolbarRoom else { return nil }
        // Stretched, the budget IS the pill's width (`PersonPill.setStretches`):
        // the room up to the repost, no Follow beside it.
        let beside = follow.stretchesPill ? nil : follow.currentFollowWidth(traits: host.traitCollection)
        return SnapToolbarFollow.pillBudget(toolbarWidth: room.width, icon: room.icon, follow: beside)
    }
}

extension SnapAuthorBar: SnapToolbarFollowHost {
    /// The Follow's face or the stretch changed: the pill's second line and
    /// stretch first, then its room, then the toolbar's items — one pass, the
    /// bar's own animation.
    func toolbarFollowDidChange() {
        guard host.layoutV2, let model = authorIdentityView.shownAuthor else { return }
        let canAnimate = host.view.window != nil && host.canAnimateBarItems
        authorIdentityView.setAuthor(
            model, pipeline: host.imagePipeline, secondLine: secondLine(for: model), animated: canAnimate
        )
        authorIdentityView.stretches = follow.stretchesPill && model.mediaURL != nil
        applyAuthorWidthBudget()
        host.toolbarComposer.refreshFollowItems()
    }

    /// Follow, or Follow back: the shared follow (#2419) — the member gate
    /// (a guest's sign-in prompt), the optimistic flip and its haptic, a
    /// refusal put back and said.
    func followShownAuthor() {
        guard let model = authorIdentityView.shownAuthor else { return }
        host.followStore.follow(
            model.authorID, handle: model.authorHandle, name: model.authorName, from: host
        )
    }

    /// Requested's "Cancel Request" (#2419's withdrawal).
    func cancelShownAuthorRequest() {
        guard let model = authorIdentityView.shownAuthor else { return }
        host.followStore.cancelRequest(to: model.authorID, handle: model.authorHandle, from: host)
    }
}
