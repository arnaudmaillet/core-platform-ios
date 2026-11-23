import CoreModels
import CoreNavigation
import CoreStorage
import EntityStore
import Foundation
import MediaCore
import MediaCoreFixtures
import UIKit
@testable import Chat

/// A builder's dependencies for a test (#2375): `repository` and, behind
/// their flags, the groups and channels; every other collaborator inert —
/// no suggestions, no directory hits, no faces, no relation marks, routes
/// that go nowhere, a search history of its own.
@MainActor
extension ChatFeatureBuilder.Dependencies {
    static func testing(
        repository: any ChatProviding,
        groups: (any GroupChatServicing)? = nil,
        channels: (any ChatConversationServicing)? = nil
    ) -> Self {
        let entities = EntityStore()
        return Self(
            repository: repository,
            presence: SectionPresenceStore(scope: StorageScope()),
            voicePlayed: VoicePlayedStore(scope: StorageScope()),
            connections: InertConnections(),
            people: InertPeopleDirectory(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            router: InertRouter(),
            recentSearches: RecentSearchStore(defaults: UserDefaults(suiteName: "chat-builder-\(UUID().uuidString)")!),
            mediaPicker: { _, _ in UIViewController() },
            localStore: nil,
            relations: InboxRelations(entities: entities, reader: nil, writer: nil),
            groups: groups,
            channels: channels,
            postsPage: { nil },
            socialGraph: InertSocialGraph(),
            followRelations: InertSocialGraph(),
            entities: entities
        )
    }
}

private actor InertConnections: SuggestionsProviding, PeerAvatarProviding {
    func suggestions(limit: Int) async throws -> [SuggestedAccount] { [] }
    func follow(_ profileID: ProfileID) async throws -> FollowOutcome { .following }
    func unfollow(_ profileID: ProfileID) async throws {}
    func avatarURLs(for ids: [ProfileID]) async -> [ProfileID: URL] { [:] }
}

private actor InertPeopleDirectory: PeopleDirectoryProviding {
    func searchPeople(matching query: String, limit: Int32) async throws -> [DirectoryPerson] { [] }
    func searchPeoplePage(matching query: String, limit: Int32, pageToken: String?) async throws -> DirectoryPage {
        DirectoryPage(people: [], nextPageToken: nil)
    }
}

private final class InertRouter: Router {
    func route(to route: AppRoute) {}
}

private actor InertSocialGraph: SocialGraphReading, SocialGraphWriting {
    func followRelation(to profileID: ProfileID) async throws -> FollowRelation { .notFollowing }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func follow(_ profileID: ProfileID) async throws -> FollowOutcome { .following }
}
