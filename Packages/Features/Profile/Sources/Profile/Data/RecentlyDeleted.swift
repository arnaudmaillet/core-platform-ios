import CoreContracts
import CoreModels
import Foundation
import PostGrid

/// A deleted post that can still come back (#408, backend #663): restorable
/// for 30 days after it was deleted.
public struct DeletedPost: Equatable, Sendable {
    public static let restoreWindowDays = 30

    public let post: GalleryPost
    public let deletedAt: Date?

    public init(post: GalleryPost, deletedAt: Date?) {
        self.post = post
        self.deletedAt = deletedAt
    }

    /// When the restore option ends; nil when the deletion date is unknown.
    public var restorableUntil: Date? {
        deletedAt.map { $0.addingTimeInterval(TimeInterval(Self.restoreWindowDays) * 86_400) }
    }

    /// Whole days left to restore it, never below zero: 30 on the day of
    /// the deletion, one fewer at each local midnight, 0 ("Last day") on the
    /// thirtieth day after it.
    ///
    /// Counted in CALENDAR days, in the zone's own rules, from the deletion's
    /// day — not from `restorableUntil`. The window is 30 × 24 h, so a change
    /// of clocks inside it moves its last instant by an hour: read as a day,
    /// it fell on the day before (a post deleted at 00:30 read "29 days
    /// left" at once), and pinning the count to one UTC offset instead made
    /// it skip a number at the end of daylight saving (12, 10) and repeat
    /// one at its start (22, 22). An hour either way at the very end of the
    /// window is the price of a count that moves by one a day.
    public func daysLeft(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let deletedAt,
              let lastDay = calendar.date(byAdding: .day, value: Self.restoreWindowDays, to: calendar.startOfDay(for: deletedAt))
        else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: lastDay).day ?? 0
        return max(days, 0)
    }
}

public enum PostRestoreError: Error, Equatable {
    /// PST-1007: more than 30 days ago.
    case tooLate
    /// PST-1006: it isn't deleted (restored meanwhile).
    case notDeleted
    case transport(message: String)
}

/// Delete a post of one's own, and bring it back within 30 days
/// (Settings → Your Activity → Recently Deleted).
public protocol PostTrashManaging: Sendable {
    func deletePost(_ postID: PostID, author: ProfileID) async throws
    /// Newest deletion first.
    func recentlyDeleted(for author: ProfileID) async throws -> [DeletedPost]
    func restorePost(_ postID: PostID, author: ProfileID) async throws
}

extension ProfileGalleryRepository: PostTrashManaging {
    public func deletePost(_ postID: PostID, author: ProfileID) async throws {
        var request = Post_V1_DeletePostRequest()
        request.postID = postID.rawValue
        request.profileID = author.rawValue
        let response = await postClient.deletePost(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func recentlyDeleted(for author: ProfileID) async throws -> [DeletedPost] {
        var views: [Post_V1_PostView] = []
        var pageToken = ""
        // Bounded: a page can come back short with its token still valid.
        for _ in 0..<20 {
            var request = Post_V1_ListRecentlyDeletedRequest()
            request.profileID = author.rawValue
            request.limit = 50
            request.pageToken = pageToken
            let response = await postClient.listRecentlyDeleted(request: request, headers: [:])
            switch response.result {
            case .success(let body):
                views += body.posts
                pageToken = body.nextToken
            case .failure(let error):
                throw ProfileError.transport(message: error.message ?? "code \(error.code)")
            }
            if pageToken.isEmpty { break }
        }
        let deletedAt = Dictionary(views.map { ($0.postID, $0.deletedAtMs) }, uniquingKeysWith: { first, _ in first })
        let posts = await withAuthors(views.map(HydratedPost.init(view:)))
        return posts.map { post in
            let ms = deletedAt[post.id.rawValue] ?? 0
            return DeletedPost(post: post, deletedAt: ms > 0 ? Date(timeIntervalSince1970: TimeInterval(ms) / 1_000) : nil)
        }
    }

    public func restorePost(_ postID: PostID, author: ProfileID) async throws {
        var request = Post_V1_RestorePostRequest()
        request.postID = postID.rawValue
        request.profileID = author.rawValue
        let response = await postClient.restorePost(request: request, headers: [:])
        if let error = response.error {
            let message = error.message ?? ""
            if message.contains("PST-1007") { throw PostRestoreError.tooLate }
            if message.contains("PST-1006") { throw PostRestoreError.notDeleted }
            throw PostRestoreError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
