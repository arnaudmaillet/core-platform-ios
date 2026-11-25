import CoreModels
import Foundation

/// The viewer's friends — the people they follow who follow them back — for
/// the "New message" sheet's first section (#2411): a message to anyone else
/// lands in their Requests, so the people who will get it for sure come
/// first.
///
/// Chat states the shape it needs; the composition root answers it with the
/// app's one mutual-follow read (`ProfileRelationshipsRepository`'s Friends
/// list, the profile's Friends tab), so the intersection is never written a
/// second time here. Same arrangement as `PeopleDirectoryProviding`.
public protocol FriendsProviding: Sendable {
    /// At most `limit` of the viewer's friends, in the graph's order.
    func friends(limit: Int) async throws -> [DirectoryPerson]
}
