import Auth
import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworkingMocks
import EntityStore
import FeedInterface
import Foundation
import LocalStore
import MediaCore
import Notifications
import NotificationsInterface
import UIKit

// Notifications (#2375): the drawer's repository and builder, and push
// notifications. Its properties are declared in `AppContainer.swift`, since an
// extension holds no stored property; they are built here.
extension AppContainer {
    func makeNotificationsRepository() -> NotificationsRepository {
        NotificationsRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: authenticatedRPCClient),
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
            // The subject post's still (or a text post's opening) for each row.
            postClient: Post_V1_PostServiceClient(client: authenticatedRPCClient),
            authSession: sessionManager,
            viewer: viewerSession,
            clear: notificationsClear,
            people: entityStore
        )
    }

    /// The server's clear of the drawer (#1574): the mock's, reached
    /// directly — notification.v1 carries no clear until backend #971. Nil on
    /// the fleet, where the trash is not offered.
    private var notificationsClear: NotificationsClearing? {
        guard environment == .mock else { return nil }
        let service = mockBackend.notificationService
        return { profileID, bound in
            service.clear(
                profileID: profileID, newestID: bound.newestID,
                throughMs: Int64(bound.newestCreatedAt.timeIntervalSince1970 * 1_000)
            )
        }
    }

    func makePushNotifications() -> PushNotifications {
        PushNotifications(
            registering: notificationsRepository,
            // The login's own device id — the edge registers a session's own
            // device only.
            deviceID: Self.persistentDeviceID(),
            // Routes only once the shell exists; a tap before it waits.
            router: { [weak self] in
                guard let self, routeResolver.navigator != nil else { return nil }
                return router
            },
            postOfComment: Self.postOfComment(
                using: Comment_V1_CommentServiceClient(client: authenticatedRPCClient)
            )
        )
    }

    /// A comment's post, for a tap on a comment's notification: the payload
    /// names the comment, and a post is what opens.
    private nonisolated static func postOfComment(
        using comments: Comment_V1_CommentServiceClient
    ) -> @Sendable (String) async -> PostID? {
        { commentID in
            var request = Comment_V1_GetCommentRequest()
            request.commentID = commentID
            guard case .success(let comment) = await comments.getComment(request: request, headers: [:]).result,
                  !comment.postID.isEmpty
            else { return nil }
            return PostID(comment.postID)
        }
    }

    func makeNotificationsFeature() -> any NotificationsFeatureBuilding {
        NotificationsFeatureBuilder(dependencies: .init(
            repository: notificationsRepository,
            router: routeResolver,
            imagePipeline: imagePipeline,
            // The drawer's last 100 notifications (#897).
            localStore: localStore,
            // Pauses past 8 h and "until I turn it back on" (#1575): the mock
            // accepts them; the fleet will once backend #971 lands.
            allowsLongPushPauses: environment == .mock,
            // The trash (#1574), where the server can clear: the mock, until
            // backend #971.
            allowsClearAll: notificationsClear != nil,
            // A post notification opens the vertical feed above the drawer (#1577).
            openPost: { [unowned self] opening in NotificationPostFeed.open(opening, feed: self.feedFeature) },
            viewerEvents: viewerEvents
        ))
    }
}
