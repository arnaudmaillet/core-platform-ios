import CoreModels
import Foundation
import Testing
@testable import Feed

/// Likes always show (#1713, the owner): the client honours no "likes
/// hidden" — the field is gone from the model — and what older builds wrote
/// still decodes.
struct HiddenLikeCountsTests {
    /// A snapshot written while the field existed — hidden or not — still
    /// decodes; the key is ignored.
    @Test func anOlderSnapshotWithTheFieldStillDecodes() throws {
        for hidden in [true, false] {
            let json = #"{"id":"p","authorID":"a","caption":"","attachments":[],"publishedAt":0,"likeCountsHidden":"# + "\(hidden)}"
            let post = try JSONDecoder().decode(Post.self, from: Data(json.utf8))
            #expect(post.id == PostID("p"))
        }
    }
}
