import CoreModels
import Foundation
import LocalStore
import Testing
@testable import Profile

/// Followers, Following and Friends open on their last first page (#1776):
/// at the next visit or launch, with no skeleton, then revalidate in place.
@MainActor
struct RelationshipsCacheFirstTests {
    private final class Folder: Sendable {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "RelationshipsCacheFirstTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private actor Lists: ProfileRelationshipsProviding {
        let supportsFollowerRemoval = false
        private var offline = false
        private(set) var asks = 0
        func goOffline() { offline = true }

        func relationships(
            for profileID: ProfileID, direction: RelationshipDirection, pageToken: String, limit: Int32
        ) async throws -> RelationshipPage {
            asks += 1
            if offline { throw RelationshipsError.transport(message: "offline", failure: .offline) }
            return RelationshipPage(relations: [
                ProfileRelation(
                    id: ProfileID("ava"), handle: "ava", displayName: "Ava", avatarURL: nil, isVerified: true,
                    viewerFollows: true, isViewer: false
                ),
                ProfileRelation(
                    id: ProfileID("leo"), handle: "leo", displayName: "Leo", avatarURL: nil, isVerified: false,
                    viewerFollows: false, isViewer: false, viewerRequested: true
                ),
            ], nextPageToken: "p2")
        }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func removeFollower(_ profileID: ProfileID) async throws {}
        func invalidateViewerCache() async {}
    }

    private let folder = Folder()

    private func launch(as viewer: LocalStoreViewer = .member(account: "acct-1", profile: "me")) throws -> ProfileRelationshipsLocalCache {
        ProfileRelationshipsLocalCache(store: try LocalStore(directory: folder.url, viewer: { viewer }))
    }

    private func open(_ lists: Lists, cache: ProfileRelationshipsLocalCache) -> ProfileRelationshipsViewModel {
        ProfileRelationshipsViewModel(
            subject: ProfileRelationshipsViewModel.Subject(
                id: ProfileID("subject"), handle: "subject", visibility: .public, viewerFollowsSubject: true,
                isSelf: false, followerCount: .exact(2), followingCount: .exact(2)
            ),
            repository: lists, deviceCache: cache
        )
    }

    private func rows(_ phase: ProfileRelationshipsViewModel.Phase) -> [ProfileID] {
        guard case .content(let rows, _) = phase else { return [] }
        return rows.map(\.id)
    }

    private func settle(until condition: () async -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func aListOpensOnItsLastFirstPageThenRevalidates() async throws {
        let lists = Lists()
        let first = try launch()
        let visit = open(lists, cache: first)
        #expect(visit.phase(for: .followers) == .loading, "a cold device opened on rows")
        visit.viewDidLoad()
        #expect(await settle { rows(visit.phase(for: .followers)).count == 2 })
        first.waitForPendingWrites()

        await lists.goOffline()
        let again = open(lists, cache: try launch())
        #expect(rows(again.phase(for: .followers)) == [ProfileID("ava"), ProfileID("leo")], "the first frame was a skeleton")
        let stored = try #require(try launch().firstPage(of: ProfileID("subject"), .followers))
        #expect(stored.relations.last?.viewerRequested == true, "the row's state did not survive the record")
        #expect(stored.nextPageToken == "p2")

        again.viewDidLoad()
        #expect(await settle { await lists.asks == 2 }, "the stored list was not revalidated")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rows(again.phase(for: .followers)).count == 2, "a failed revalidation took the rows back")
    }

    @Test func anotherAccountOpensOnASkeleton() async throws {
        let lists = Lists()
        let mine = try launch()
        let visit = open(lists, cache: mine)
        visit.viewDidLoad()
        #expect(await settle { rows(visit.phase(for: .followers)).count == 2 })
        mine.waitForPendingWrites()

        let theirs = open(lists, cache: try launch(as: .member(account: "acct-2", profile: "them")))
        #expect(theirs.phase(for: .followers) == .loading)
    }
}
