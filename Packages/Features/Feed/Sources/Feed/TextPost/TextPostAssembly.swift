import CoreModels
import CoreNavigation
import CoreStorage
import EntityStore
import FeedInterface
import MediaCore
import PostGrid
import PostSurfaces
import ProfileInterface
import ThreadKit
import UIKit

/// The text post screen: the "+" menu's Text Post and a channel's "Share as
/// a Post", over the comments panel's own construction. Built once by
/// `FeedFeatureBuilder`.
@MainActor
struct TextPostAssembly {
    private let repository: any FeedProviding
    private let engagementProvider: (any EngagementProviding)?
    private let commentsProvider: (any CommentsProviding)?
    private let router: any Router
    private let imagePipeline: ImagePipeline
    private let makeProfileSwitcher: @MainActor () -> (any ProfileSwitcherPresenting)?
    private let wallet: (any WalletStaking)?
    private let makeWalletSheet: (@MainActor () -> UIViewController)?
    private let entities: any EntityReading & EntityWriting
    private let unavailablePosts: UnavailablePosts
    private let bookmarks: PostBookmarkStore
    /// The Text Post page's drafts. The app hands in its one store (built
    /// once in `AppContainer`, charter P4); a test hands in one of its own.
    private let postDrafts: PostDraftStore
    /// Read as each screen is built, for `balanceWallet`: the guest rule is
    /// written once, on `Dependencies`.
    private let dependencies: FeedFeatureBuilder.Dependencies

    init(dependencies: FeedFeatureBuilder.Dependencies) {
        repository = dependencies.repository
        engagementProvider = dependencies.engagementProvider
        commentsProvider = dependencies.commentsProvider
        router = dependencies.router
        imagePipeline = dependencies.imagePipeline
        makeProfileSwitcher = dependencies.makeProfileSwitcher
        wallet = dependencies.wallet
        makeWalletSheet = dependencies.makeWalletSheet
        entities = dependencies.entities
        unavailablePosts = dependencies.unavailablePosts
        bookmarks = dependencies.bookmarks
        postDrafts = dependencies.postDrafts
        self.dependencies = dependencies
    }

    /// The "+" menu's Text Post: a text post's own page, born empty, in an
    /// expandable sheet — the content of an empty page is one invitation, and
    /// a full screen of it was mostly air.
    ///
    /// ⚠️ THE PANEL IS THE TEXT PAGE'S REAL ONE, built by `makeCommentsPanel`
    /// like every page's, over a DRAFT: no post, nothing fetched, and a first
    /// send that publishes the post instead of commenting on one. Everything
    /// the published page reads is primed before the panel turns into it — the
    /// entry held so it is never fetched back, its empty first page of
    /// comments — and from then on the sheet is that post's.
    public func makeTextPostScreen(publisher: any TextPostPublishing) -> UIViewController {
        makeTextPostScreen(publisher: publisher, bookmarks: bookmarks)
    }

    /// A channel's "Share as a Post" (#2216): the same screen, its card
    /// attached above the composer — removable — with an optional place.
    /// Opened at its full height: the card and the words need the room the
    /// keyboard would ask for anyway. Without `-channels`, the plain screen.
    public func makeTextPostScreen(publisher: any TextPostPublishing, attaching embed: PostEmbed) -> UIViewController {
        makeTextPostScreen(publisher: publisher, bookmarks: bookmarks, attaching: embed)
    }

    /// The same, over `bookmarks` — the app's one pile outside tests.
    /// `showsEmbeds`: whether a card can be attached (`-channels`);
    /// `recordsVoice`: whether the first message can be a voice
    /// (`-voice-posts`).
    func makeTextPostScreen(
        publisher: any TextPostPublishing, bookmarks: PostBookmarkStore, attaching embed: PostEmbed? = nil,
        showsEmbeds: Bool = PostEmbeds.areDrawn, recordsVoice: Bool = VoicePosts.areDrawn
    ) -> UIViewController {
        let repository = repository
        let commentsProvider = commentsProvider
        // A showcase (#2216): the same priming as a text post's; none
        // without `-channels`.
        let publishShowcase: (@Sendable (String, PostEmbed, TextPostPlace?, AuthorSummary?) async throws -> FeedEntry)?
        if showsEmbeds {
            publishShowcase = { text, embed, place, author in
                let entry = try await publisher.publishTextPost(text, embed: embed, place: place, as: author)
                await repository.remember(entry)
                commentsProvider?.seedTopComments([], for: entry.post.id)
                return entry
            }
        } else {
            publishShowcase = nil
        }
        let attached: PostEmbed? = showsEmbeds ? embed : nil
        // A voice post (#2209): the same priming as a text post's; none
        // without `-voice-posts`.
        let publishVoice: (@Sendable (String, TextPostVoice, AuthorSummary?) async throws -> FeedEntry)?
        if recordsVoice {
            publishVoice = { text, voice, author in
                let entry = try await publisher.publishTextPost(text, voice: voice, as: author)
                await repository.remember(entry)
                commentsProvider?.seedTopComments([], for: entry.post.id)
                return entry
            }
        } else {
            publishVoice = nil
        }
        let draft = PostDetailDraft(publish: { text, author in
            let entry = try await publisher.publishTextPost(text, as: author)
            await repository.remember(entry)
            commentsProvider?.seedTopComments([], for: entry.post.id)
            return entry
        }, publishVoice: publishVoice, publishShowcase: publishShowcase)
        let panel = PostCommentsAssembly.makeCommentsPanel(
            viewModel: PostDetailViewModel(
                draft: draft,
                repository: repository,
                engagementProvider: engagementProvider,
                commentsProvider: commentsProvider,
                router: router,
                entities: entities
            ),
            threadChrome: true,
            imagePipeline: imagePipeline,
            makeProfileSwitcher: makeProfileSwitcher,
            stakes: wallet.map { .own(StakeSession(wallet: $0)) },
            viewerEvents: unavailablePosts.viewerEvents
        )
        let composer = TextPostComposerViewController(
            panel: panel,
            drafts: postDrafts,
            imagePipeline: imagePipeline,
            router: router,
            // The composer's wallet is its badge alone: none for a guest.
            wallet: dependencies.balanceWallet,
            makeWalletSheet: makeWalletSheet,
            // A save made elsewhere while the page shows the post (#1067).
            entities: entities,
            bookmarks: bookmarks,
            attaching: attached
        )
        let navigation = UINavigationController(rootViewController: composer)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            // Half height for an empty page — taller only when the invitation
            // cannot show whole there — and the whole screen for a thread and
            // for the keyboard, which the composer grows the sheet for.
            sheet.detents = [composer.makeRestingDetent(), .large()]
            sheet.prefersGrabberVisible = true
            // A showcase opens full height (#2216): its card is taller than
            // the invitation it stands in for.
            if attached != nil { sheet.selectedDetentIdentifier = .large }
        }
        return navigation
    }
}
