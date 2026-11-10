import CoreModels
import PostGrid
import Testing
import UIKit
@testable import Feed

/// A channel showcase's menu (#2216): no Comment row, since a showcase takes
/// no comments; every other row as for any text post.
@MainActor
struct ShowcaseMenuRowsTests {
    private func post(embed: PostEmbed?) -> GalleryPost {
        var post = GalleryPost(
            id: PostID("p-showcase"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: "Boats in at six", publishedAtMS: 1_800_000_000_000,
            authorID: ProfileID("a1"), authorName: "Ava Moreau", authorHandle: "ava", reactionCount: 12
        )
        post.embed = embed
        return post
    }

    private let harbour = PostEmbed.channel(ChannelEmbed(conversationID: ConversationID("ch-harbour"), name: "Harbour notes"))

    private func hasComment(_ rows: [PostCardMenuAction]) -> Bool {
        rows.contains { if case .comment = $0 { true } else { false } }
    }

    @Test func aShowcaseOffersNoComment() {
        let menu = PostMenuRows(comment: {}, showsEmbeds: true)
        let rows = menu.rows(for: post(embed: harbour), anchor: UIView())
        #expect(!hasComment(rows))
        #expect(rows.contains { if case .share = $0 { true } else { false } }, "Share stays")
    }

    @Test func aPlainTextPostStillOffersComment() {
        let menu = PostMenuRows(comment: {}, showsEmbeds: true)
        #expect(hasComment(menu.rows(for: post(embed: nil), anchor: UIView())))
    }

    @Test func withTheSwitchOffAShowcaseIsAPlainTextPost() {
        let menu = PostMenuRows(comment: {}, showsEmbeds: false)
        #expect(hasComment(menu.rows(for: post(embed: harbour), anchor: UIView())))
    }
}
