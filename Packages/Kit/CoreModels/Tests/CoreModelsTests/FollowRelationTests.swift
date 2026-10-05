import Testing
@testable import CoreModels

/// A follow or an unfollow moves the OUTBOUND half of the edge only: whether
/// they follow the viewer is theirs, and it is what decides between a one-way
/// follow and a friend.
struct FollowRelationTests {
    @Test(arguments: [
        (FollowRelation.notFollowing, true, FollowRelation.following),
        (.followedBy, true, .mutual),
        (.following, false, .notFollowing),
        (.mutual, false, .followedBy),
        // Already there: nothing moves.
        (.following, true, .following),
        (.mutual, true, .mutual),
        (.notFollowing, false, .notFollowing),
        (.followedBy, false, .followedBy),
    ])
    func aFollowMovesOnlyTheViewersHalf(_ from: FollowRelation, _ follows: Bool, _ to: FollowRelation) {
        #expect(from.settingFollow(follows) == to)
    }

    @Test(arguments: [FollowRelation.viewer, .blocked], [true, false])
    func theViewerAndTheBlockedNeverMove(_ relation: FollowRelation, _ follows: Bool) {
        #expect(relation.settingFollow(follows) == relation)
    }

    @Test func onlyThePeopleTheViewerDoesNotFollowOfferFollow() {
        #expect(FollowRelation.notFollowing.offersFollow)
        #expect(FollowRelation.followedBy.offersFollow, "following back is a follow")
        for relation in [FollowRelation.viewer, .following, .mutual, .blocked] {
            #expect(!relation.offersFollow)
        }
        #expect(FollowRelation.following.isFollowing)
        #expect(FollowRelation.mutual.isFollowing)
        #expect(!FollowRelation.followedBy.isFollowing)
    }

    /// A pending request (#396) is neither a follow nor an offer to follow;
    /// following again keeps it pending, an unfollow (a withdrawal) clears it.
    @Test func aPendingRequestIsNotAFollow() {
        #expect(!FollowRelation.requested.offersFollow)
        #expect(!FollowRelation.requested.isFollowing)
        #expect(FollowRelation.requested.settingFollow(true) == .requested)
        #expect(FollowRelation.requested.settingFollow(false) == .notFollowing)
    }
}
