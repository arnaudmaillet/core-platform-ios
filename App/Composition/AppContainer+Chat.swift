import Auth
import AuthInterface
import Chat
import ChatInterface
import Connect
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreStorage
import EntityStore
import FeedInterface
import Foundation
import LaunchArguments
import LocalStore
import MediaCore
import MediaPlayback
import PostGrid
import ProfileData
import UIKit
import Upload

// Chat (#2375): the conversations' repositories and builder, the thread's media
// picker and the channel showcase's actions. Its properties are declared in
// `AppContainer.swift`, since an extension holds no stored property; they are
// built here.
extension AppContainer {
    /// What a channel showcase's card does (#2216) — Join, Request to join,
    /// cancel, Open — registered at launch on the card (`PostEmbedView`),
    /// which Feed, Maps and Profile draw and which can't reach Chat: Chat's
    /// own, over the repository and the catalog Chats reads (#2230). Made
    /// on the first tap, not here: building Chat is no launch's business,
    /// and a launch that lands on a post never opens Messages. Nil with
    /// `-channels` off (`ChatFeatureBuilder.makeChannelEmbedActions`).
    @MainActor
    func installChannelEmbedActions() {
        PostEmbedView.makeChannelActions = { [unowned self] in chatFeature.makeChannelEmbedActions() }
    }

    func makeChatRepository() -> ChatRepository {
        ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: authenticatedRPCClient),
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
            authSession: sessionManager,
            viewer: viewerSession,
            // A message's photo or video goes up the way a post's does (#681).
            mediaUploader: MediaAssetUploader(
                mediaClient: Media_V1_MediaServiceClient(client: authenticatedRPCClient),
                transport: mediaUploadTransport
            ),
            inboxPageSize: Self.inboxPageSize,
            // Groups' and channels' own calls (#2213), on backend #995's shape.
            proposals: ProposedChatClient(client: authenticatedRPCClient)
        )
    }

    /// The thread's camera and library (#681): the upload flow's own sheet,
    /// in its send mode, its picks spelled as Chat sends them.
    private var chatMediaPicker: ChatMediaPickerFactory {
        { [unowned self] source, completion in
            self.uploadFeature.makeSendMediaPicker(source == .camera ? .camera : .library) { picked in
                completion(picked.map(Self.chatUpload))
            }
        }
    }

    private static func chatUpload(_ picked: PickedSendMedia) -> ChatMediaUpload {
        switch picked {
        case .photo(let image):
            .image(image)
        case .video(let exported, let poster):
            .video(ChatVideoUpload(
                fileURL: exported.fileURL, mimeType: exported.mimeType, poster: poster,
                pixelWidth: exported.pixelWidth, pixelHeight: exported.pixelHeight,
                duration: exported.durationSeconds,
                // The bubble owns the export: deleted once sent or discarded (#898).
                fileOwner: exported.file
            ))
        }
    }

    /// `-mock-group-private-after <seconds>` (DEBUG, #2217): the public
    /// group the mock's viewer follows is turned private by its owner that
    /// long after launch — so a follower can watch "This group is private
    /// now" with its thread open, the mock having no other account to do it.
    static var groupGoesPrivateAfter: TimeInterval? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let seconds = LaunchArgument.mockGroupPrivateAfter.doubleValue(in: arguments), seconds >= 0 {
            return seconds
        }
        #endif
        return nil
    }

    /// Conversations per inbox page (#593).
    ///
    /// `-inbox-page-size <n>` (DEBUG): smaller pages, so the mock's sixteen
    /// conversations and five requests page on the simulator at all — at the
    /// real size they fit in one.
    private static var inboxPageSize: Int32 {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let size = LaunchArgument.inboxPageSize.value(in: arguments).flatMap { Int32($0) }, size > 0 {
            return size
        }
        #endif
        return 20
    }

    func makeSocialConnectionsRepository() -> SocialConnectionsRepository {
        SocialConnectionsRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
            viewer: chatRepository,
            pageSize: 200,
            followEvents: followGraphEvents,
            people: entityStore
        )
    }

    func makePeopleDirectoryRepository() -> PeopleDirectoryRepository {
        PeopleDirectoryRepository(
            searchClient: Search_V1_SearchServiceClient(client: authenticatedRPCClient)
        )
    }

    func makeInboxRelations() -> InboxRelations {
        InboxRelations(
            entities: entityStore, reader: profileRepository, writer: profileRepository
        )
    }

    func makeChatFeature() -> any ChatFeatureBuilding {
        ChatFeatureBuilder(
            repository: chatRepository,
            connections: socialConnectionsRepository,
            people: peopleDirectoryRepository,
            imagePipeline: imagePipeline,
            router: routeResolver,
            // One history for the whole app: a query typed in the inbox is recent on
            // the search screen, and the other way round.
            recentSearches: recentSearchStore,
            mediaPicker: chatMediaPicker,
            // The inbox and the last 50 conversations × 200 messages (#897).
            localStore: localStore,
            relations: inboxRelations,
            // The Posts page under a group's or a channel's info header (#2237):
            // For You's own grid, as the profile's and the place's pages — the
            // text posts that showcase it, laid out as a profile's Posts.
            postsPage: { [unowned self] in self.feedFeature.makePostGridPage(style: .list, savesPosts: false) },
            // The conversation's peer pill follows and marks through the SAME
            // repositories and store the feed's author pill does (#752, #2049):
            // the conversation is Chat's own screen since #2380.
            socialGraph: profileRepository,
            followRelations: profileRepository,
            entities: entityStore
        )
    }
}
