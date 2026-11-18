import CacheKit
import CoreModels
import Foundation
import LocalStore

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
package final class ProfileRelationshipsLocalCache: Sendable {
    package static let entityType = "profile.relation"
    package static let format = 1

    private let list: LocalRecordList<Record>

    package init(store: LocalStore) {
        list = LocalRecordList(store: store, entityType: Self.entityType, format: Self.format, name: "relationships")
    }

    /// Who a page is being fetched for, captured before the fetch.
    package var viewer: LocalStoreViewer? { list.viewer }

    package func firstPage(of subject: ProfileID, _ direction: RelationshipDirection) -> RelationshipPage? {
        guard let stored = list.read(Self.listKey(subject, direction), maxPages: 1) else { return nil }
        return RelationshipPage(relations: stored.records.compactMap(\.relation), nextPageToken: stored.nextCursor ?? "")
    }

    /// Replaces the stored first page. The viewer's own lists are kept
    /// (`retained`); someone else's go first under pressure.
    package func storeFirstPage(
        _ page: RelationshipPage, of subject: ProfileID, _ direction: RelationshipDirection,
        isSelf: Bool, as viewer: LocalStoreViewer?
    ) {
        list.write(
            page.relations.map { (id: $0.id.rawValue, record: Record($0)) }, to: Self.listKey(subject, direction),
            nextCursor: page.nextPageToken.isEmpty ? nil : page.nextPageToken, as: viewer,
            lifetime: LocalStorePolicy.profileLifetime, tier: isSelf ? .retained : .recent
        )
    }

    package static func listKey(_ subject: ProfileID, _ direction: RelationshipDirection) -> String {
        let name = switch direction {
        case .followers: "followers"
        case .following: "following"
        case .friends: "friends"
        }
        return "relationships.\(subject.rawValue).\(name)"
    }

    /// Waits for every write queued so far. Tests only.
    package func waitForPendingWrites() {
        list.waitForPendingWrites()
    }

    /// One row as stored.
    package struct Record: Codable, Equatable {
        package var id: String
        package var handle: String
        package var displayName: String
        package var avatarURL: URL?
        package var isVerified: Bool
        package var viewerFollows: Bool
        package var isViewer: Bool
        package var viewerRequested: Bool
        package var canFollow: Bool

        package init(_ relation: ProfileRelation) {
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

        package var relation: ProfileRelation {
            ProfileRelation(
                id: ProfileID(id), handle: handle, displayName: displayName, avatarURL: avatarURL,
                isVerified: isVerified, viewerFollows: viewerFollows, isViewer: isViewer,
                viewerRequested: viewerRequested, canFollow: canFollow
            )
        }
    }
}
