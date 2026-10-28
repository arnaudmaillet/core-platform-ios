import CacheKit
import CoreModels
import Foundation
import LocalStore
import OSLog

/// A profile's Followers, Following and Friends lists on the device (#1776),
/// in the LocalStore: a list opens on its last first page at the next visit
/// or launch, with no skeleton, then revalidates in place.
///
/// One list per subject and direction (`relationships.<id>.<direction>`), the
/// first page only, with the cursor past it. A person is a versioned JSON
/// record, a format this build cannot read is a miss. `viewerFollows` and
/// its kin are the viewer's own view of the row, which the store's viewer
/// scope keeps right: another account reads none of it, and a switch wipes
/// it with the other device caches.
///
/// Reads are synchronous (the list's first frame); writes go to a serial
/// queue, each as the viewer captured BEFORE its network call.
final class ProfileRelationshipsLocalCache: Sendable {
    static let entityType = "profile.relation"
    static let format = 1

    private let store: LocalStore
    private let queue = DispatchQueue(label: "cn.wynn.relationships-local-cache", qos: .utility)
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "relationships-cache")

    init(store: LocalStore) {
        self.store = store
    }

    /// Who a page is being fetched for, captured before the fetch.
    var viewer: LocalStoreViewer? { store.currentViewer }

    func firstPage(of subject: ProfileID, _ direction: RelationshipDirection) -> RelationshipPage? {
        guard let list = store.list(Self.listKey(subject, direction), maxPages: 1) else { return nil }
        let relations = list.entries.compactMap { entity -> ProfileRelation? in
            guard entity.key.type == Self.entityType, entity.format == Self.format,
                  let record = try? JSONDecoder().decode(Record.self, from: entity.payload) else { return nil }
            return record.relation
        }
        return RelationshipPage(relations: relations, nextPageToken: list.nextCursor ?? "")
    }

    /// Replaces the stored first page. The viewer's own lists are kept
    /// (`retained`); someone else's go first under pressure.
    func storeFirstPage(
        _ page: RelationshipPage, of subject: ProfileID, _ direction: RelationshipDirection,
        isSelf: Bool, as viewer: LocalStoreViewer?
    ) {
        let store = store
        let logger = logger
        queue.async {
            let encoder = JSONEncoder()
            let writes = page.relations.compactMap { relation -> LocalEntityWrite? in
                guard let payload = try? encoder.encode(Record(relation)) else { return nil }
                return LocalEntityWrite(
                    key: LocalEntityKey(type: Self.entityType, id: relation.id.rawValue),
                    payload: payload, format: Self.format, lifetime: LocalStorePolicy.profileLifetime
                )
            }
            let listPage = LocalListPage(
                items: writes.map(\.key), entities: writes,
                nextCursor: page.nextPageToken.isEmpty ? nil : page.nextPageToken,
                tier: isSelf ? .retained : .recent
            )
            do {
                try store.replaceList(
                    Self.listKey(subject, direction), with: listPage, as: viewer,
                    lifetime: LocalStorePolicy.profileLifetime
                )
            } catch {
                logger.error("relationships cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func listKey(_ subject: ProfileID, _ direction: RelationshipDirection) -> String {
        let name = switch direction {
        case .followers: "followers"
        case .following: "following"
        case .friends: "friends"
        }
        return "relationships.\(subject.rawValue).\(name)"
    }

    /// Waits for every write queued so far. Tests only.
    func waitForPendingWrites() {
        queue.sync {}
        store.waitForPendingWrites()
    }

    /// One row as stored.
    struct Record: Codable, Equatable {
        var id: String
        var handle: String
        var displayName: String
        var avatarURL: URL?
        var isVerified: Bool
        var viewerFollows: Bool
        var isViewer: Bool
        var viewerRequested: Bool
        var canFollow: Bool

        init(_ relation: ProfileRelation) {
            id = relation.id.rawValue
            handle = relation.handle
            displayName = relation.displayName
            avatarURL = relation.avatarURL
            isVerified = relation.isVerified
            viewerFollows = relation.viewerFollows
            isViewer = relation.isViewer
            viewerRequested = relation.viewerRequested
            canFollow = relation.canFollow
        }

        var relation: ProfileRelation {
            ProfileRelation(
                id: ProfileID(id), handle: handle, displayName: displayName, avatarURL: avatarURL,
                isVerified: isVerified, viewerFollows: viewerFollows, isViewer: isViewer,
                viewerRequested: viewerRequested, canFollow: canFollow
            )
        }
    }
}
