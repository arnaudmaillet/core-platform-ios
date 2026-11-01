import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import Testing
@testable import CoreNetworking

private struct PreviewToken: AuthTokenProviding {
    let token: String?
    func validAccessToken() async throws -> String? { token }
}

/// The mock's comment.v1 additions from the contracts bump: `ListPreviews`
/// (#976), the first comments of many posts in one call, and `ListTopLevel`
/// sorted by `popularity` (#977).
struct MockCommentPreviewsTests {
    private let backend = MockBackend()

    private func comments(_ token: String = "member-token") -> Comment_V1_CommentServiceClient {
        Comment_V1_CommentServiceClient(client: ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: PreviewToken(token: token), httpClient: backend.bff
        ))
    }

    private func firstPage(_ postID: String, sort: Comment_V1_ReplySort = .unspecified) async throws -> [Comment_V1_CommentView] {
        var request = Comment_V1_ListTopLevelRequest()
        request.postID = postID
        request.sort = sort
        return try await comments().listTopLevel(request: request, headers: [:]).result.get().comments
    }

    private func previews(_ postIDs: [String], limit: Int32 = 0, token: String = "member-token") async -> ResponseMessage<Comment_V1_ListPreviewsResponse> {
        var request = Comment_V1_ListPreviewsRequest()
        request.postIds = postIDs
        request.limit = limit
        return await comments(token).listPreviews(request: request, headers: [:])
    }

    /// For every post of the corpus, a preview is the prefix of the first
    /// page ListTopLevel lists: same comments, same order, same counts.
    @Test func aPreviewIsTheFirstPagesPrefixOverTheCorpus() async throws {
        let postIDs = backend.dataset.posts.map(\.postID)
        for chunk in stride(from: 0, to: postIDs.count, by: 50).map({ Array(postIDs[$0..<min($0 + 50, postIDs.count)]) }) {
            let answer = try await previews(chunk).result.get()
            #expect(answer.previews.map(\.postID) == chunk, "a readable post is missing, or out of order")
            for preview in answer.previews {
                let page = try await firstPage(preview.postID)
                #expect(Self.keys(preview.comments) == Self.keys(Array(page.prefix(5))),
                        "\(preview.postID)'s preview is not its page's prefix")
            }
        }
    }

    /// 0 means 5, at most 10; duplicates count once; more than 50 posts is
    /// refused.
    @Test func theBoundsFollowTheContract() async throws {
        let post = MockCommentService.longConversationPostIDs.first!
        #expect(try await previews([post]).result.get().previews.first?.comments.count == 5)
        #expect(try await previews([post], limit: 3).result.get().previews.first?.comments.count == 3)
        #expect(try await previews([post], limit: 40).result.get().previews.first?.comments.count == 10)
        #expect(try await previews([post, post]).result.get().previews.count == 1)
        let many = (0..<51).map { "post-\(String(format: "%04d", $0))" }
        #expect(await previews(many).error?.code == .invalidArgument)
    }

    /// A guest reads previews as it reads ListTopLevel: public posts only.
    @Test func aGuestReadsOnlyWhatItMayRead() async throws {
        let dataset = backend.dataset
        let open = try #require(dataset.posts.first { !dataset.isRelationshipsPrivate($0.authorProfileID) }?.postID)
        let closed = try #require(dataset.posts.first { dataset.isRelationshipsPrivate($0.authorProfileID) }?.postID)
        let answer = try await previews([open, closed], token: "gt-guest").result.get()
        #expect(answer.previews.map(\.postID) == [open])
    }

    /// Popularity lists the same comments as the newest order, ranked by
    /// likes; the newest order is unchanged.
    @Test func popularityRanksTheSameComments() async throws {
        let post = MockCommentService.longConversationPostIDs.first!
        let newest = try await firstPage(post)
        let unspecified = try await firstPage(post, sort: .newest)
        #expect(Self.keys(newest) == Self.keys(unspecified))
        let popular = try await firstPage(post, sort: .popularity)
        #expect(Set(popular.map(\.commentID)).isSubset(of: Set(try await allTopLevel(post).map(\.commentID))))
        #expect(popular.count == newest.count)
    }

    /// What a comment is, apart from its timestamps (the seed's are read
    /// against the clock): its id and its reply count.
    private static func keys(_ comments: [Comment_V1_CommentView]) -> [String] {
        comments.map { "\($0.commentID)#\($0.replyCount)" }
    }

    private func allTopLevel(_ postID: String) async throws -> [Comment_V1_CommentView] {
        var request = Comment_V1_ListTopLevelRequest()
        request.postID = postID
        request.limit = 100
        var all: [Comment_V1_CommentView] = []
        repeat {
            let page = try await comments().listTopLevel(request: request, headers: [:]).result.get()
            all += page.comments
            request.pageToken = page.nextToken
        } while !request.pageToken.isEmpty
        return all
    }
}
