import CoreModels
import CoreNavigation
import CoreStorage
import EntityStore
import MediaCore
import MediaUI
import PostGrid
import PostSurfaces
import ProfileInterface
import UIKit

/// The comments panel every snap page embeds, and the text post screen's
/// draft panel: one construction (`makeCommentsPanel`). Built once by
/// `FeedFeatureBuilder`.
@MainActor
struct PostCommentsAssembly {
    private let repository: any FeedProviding
    private let engagementProvider: (any EngagementProviding)?
    private let commentsProvider: (any CommentsProviding)?
    private let router: any Router
    private let entities: any EntityReading & EntityWriting
    private let imagePipeline: ImagePipeline
    /// Vends the profile switcher for the comments composer's avatar menu.
    ///
    /// A FACTORY, not an instance: `ProfileSwitcherPresenting` caches its
    /// pre-formatted rows from the last `reload()`, so each surface that
    /// offers switching holds its own — sharing one would make two screens
    /// race over the same row cache. A nil switcher leaves the composer's
    /// face inert.
    private let makeProfileSwitcher: @MainActor () -> (any ProfileSwitcherPresenting)?
    private let unavailablePosts: UnavailablePosts

    init(dependencies: FeedFeatureBuilder.Dependencies) {
        repository = dependencies.repository
        engagementProvider = dependencies.engagementProvider
        commentsProvider = dependencies.commentsProvider
        router = dependencies.router
        entities = dependencies.entities
        imagePipeline = dependencies.imagePipeline
        makeProfileSwitcher = dependencies.makeProfileSwitcher
        unavailablePosts = dependencies.unavailablePosts
    }

    /// The panel factory a snap feed hands its pages: one panel per page,
    /// each with its own profile switcher, and all on the page's `stakes`
    /// (#2532): one burst and one toast for a post, from its pill, its
    /// footer like or its panel's bar.
    func makePanelFactory(sharing stakes: StakeSession?) -> (PostID, Bool) -> UIViewController {
        let repository = repository
        let engagementProvider = engagementProvider
        let commentsProvider = commentsProvider
        let router = router
        let imagePipeline = imagePipeline
        // Hoisted like the rest: the panel factory escapes, and reaching for
        // a stored property inside it would capture the whole builder.
        let makeProfileSwitcher = makeProfileSwitcher
        let viewerEvents = unavailablePosts.viewerEvents
        let makePanel: (PostID, Bool) -> UIViewController = { postID, threadChrome in
            Self.makeCommentsPanel(
                viewModel: PostDetailViewModel(
                    postID: postID,
                    repository: repository,
                    engagementProvider: engagementProvider,
                    commentsProvider: commentsProvider,
                    router: router,
                    entities: entities
                ),
                threadChrome: threadChrome,
                imagePipeline: imagePipeline,
                makeProfileSwitcher: makeProfileSwitcher,
                // The page's: the page ends them when it leaves.
                stakes: stakes.map { .page($0) },
                viewerEvents: viewerEvents
            )
        }
        return makePanel
    }

    /// The comments panel every snap page embeds. ONE construction, so the
    /// Text Post page's draft panel is the text page's panel by definition
    /// rather than by resemblance.
    static func makeCommentsPanel(
        viewModel: PostDetailViewModel,
        threadChrome: Bool,
        imagePipeline: ImagePipeline,
        makeProfileSwitcher: @MainActor () -> (any ProfileSwitcherPresenting)?,
        stakes: PostDetailStakes?,
        viewerEvents: ViewerEvents
    ) -> PostDetailViewController {
        let panel = PostDetailViewController(
            viewModel: viewModel,
            imagePipeline: imagePipeline,
            profileSwitcher: makeProfileSwitcher(),
            stakes: stakes,
            // The app's viewer channel, which the record of withheld posts
            // already hears (#2376): the composer's face follows a switch.
            viewerEvents: viewerEvents,
            threadChrome: threadChrome,
            // Every snap page's comments group by day under Recent (#757).
            groupsByDay: true
        )
        // A reading screen: nothing plays in it (`AvatarMotionPolicy`).
        panel.traitOverrides.avatarMotionScreen = .comments
        return panel
    }
}
