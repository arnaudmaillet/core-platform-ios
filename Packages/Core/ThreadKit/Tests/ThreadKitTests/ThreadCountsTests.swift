import Testing
@testable import ThreadKit

/// The thread's counts as the rows print them (#2380). Pinned as they are:
/// they round, where the app's `CountFormatter` truncates (#2390 decides).
struct ThreadCountsTests {
    @Test func theCountsReadAsTheRowsPrintThem() {
        #expect(ThreadCounts.countText(843) == "843")
        #expect(ThreadCounts.countText(1_200) == "1.2k")
        #expect(ThreadCounts.countText(1_999) == "2.0k")
    }

    @Test func aCommentsLikesAreAValue() {
        #expect(CommentLikes(count: 3, mine: 1) == CommentLikes(count: 3, mine: 1))
    }
}
