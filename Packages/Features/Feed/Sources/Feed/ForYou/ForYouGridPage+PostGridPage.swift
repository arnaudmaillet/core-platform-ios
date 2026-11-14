import CoreModels
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// For You's page, vended across the package line (#1273): the profile's pages
/// are these. Internal witnesses satisfy the public protocol — nothing in Feed
/// becomes public for it.
extension ForYouGridPage: PostGridPage {
    func show(_ state: PostGridPageState) {
        hostedState = state
        observeWithheldPosts()
        // ⚠️ NEVER A POST THE SERVER WITHHOLDS (#2048). A profile's gallery
        // holds its corpus from its own reads, so a post learnt unavailable on
        // a feed kept its tile here — and its tap opened "This post isn't
        // available". The page leaves them out of whatever it is handed.
        let withheld = withheldPosts
        switch state {
        case .loading:
            render(ForYouPageState.loading)
        case .content(let posts):
            render(ForYouPageState.content(posts.filter { !withheld.contains($0.id) }))
        // Through the cold load's gate, as `render`'s states (#1900): a lock
        // shown before the delay had the bones land under it, and "taking
        // longer" replace it at 10 s.
        case .sections(let groups):
            let kept = groups
                .map {
                    PostGridPageSection(
                        title: $0.title, posts: $0.posts.filter { !withheld.contains($0.id) }, viewedAt: $0.viewedAt
                    )
                }
                .filter { !$0.posts.isEmpty }
            settle { [weak self] in self?.applyGroups(kept) }
        case .status(let status):
            settle { [weak self] in
                self?.showStatus(
                    symbolName: status.symbolName, title: status.title, subtitle: status.subtitle,
                    actionTitle: status.actionTitle,
                    action: status.actionTitle == nil ? nil : { [weak self] in self?.retry() }
                )
            }
        }
    }

    /// Hears the record once a host has shown something: a post learnt
    /// unavailable that this page holds leaves it at once.
    private func observeWithheldPosts() {
        guard withheldObservation.isEmpty else { return }
        withheldObservation.add(NotificationCenter.default.addObserver(
            forName: UnavailablePosts.didChange, object: nil, queue: .main
        ) { [weak self] note in
            let ids = note.userInfo?[UnavailablePosts.idsKey] as? Set<PostID> ?? []
            let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, sender == ObjectIdentifier(self.withheldPosts),
                      let state = self.hostedState, Self.holds(state, anyOf: ids) else { return }
                self.show(state)
            }
        })
    }

    private static func holds(_ state: PostGridPageState, anyOf ids: Set<PostID>) -> Bool {
        switch state {
        case .content(let posts): posts.contains { ids.contains($0.id) }
        case .sections(let groups): groups.contains { $0.posts.contains { ids.contains($0.id) } }
        case .loading, .status: false
        }
    }

    var postMenuActions: ((PostGridAuthorMenuContext) -> [PostCardMenuAction])? {
        get { authorMenuActions }
        set { authorMenuActions = newValue }
    }

    var scrollView: UIScrollView { collectionView }

    func refreshAuthorMenus() {
        for case let row as PostGridListRowCell in collectionView.subviews {
            row.refreshAuthorMenu()
        }
    }

    /// Activating a vended page also ends a round trip's handoff — the
    /// host's way back from a post it opened (the profile's rule, #951): the
    /// landing has run by then, and an unlanded return player is released.
    ///
    /// ⚠️ NEVER `setAutoplayActive(_:)` (#1292) — see the requirement.
    func setPageActive(_ active: Bool) {
        if active, playback?.isHandingOff == true { endPlaybackHandoff() }
        setAutoplayActive(active, keeping: nil)
    }
}

extension ForYouGridPage.Style {
    init(_ style: PostGridPageStyle) {
        switch style {
        case .grid: self = .grid
        case .list: self = .list
        case .discover: self = .discover
        case .rows: self = .rows
        }
    }
}

#if DEBUG
extension ForYouGridPage: PostGridPageDebugging {}
#endif

/// For You's grid page, built outside the feature's own builder — the
/// composition root's (`FeedFeatureBuilder.makePostGridPage`) and the
/// profile's tests, which draw the profile on the real page (#1273).
public enum PostGridPages {
    @MainActor
    public static func make(
        style: PostGridPageStyle, imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?, savesPosts: Bool,
        postOpenWarm: PostOpenWarm? = nil
    ) -> any PostGridPage {
        let page = ForYouGridPage(
            imagePipeline: imagePipeline, style: ForYouGridPage.Style(style),
            videoPlayback: videoPlayback, bookmarks: savesPosts ? .shared : nil
        )
        // A profile's tiles warm their posts' first comments (#2002).
        page.postOpenWarm = postOpenWarm
        return page
    }
}
