import CoreModels
import Foundation
import Testing
@testable import Profile

struct ProfileDisplayModelTests {
    private func profile(
        handle: String = "ada",
        displayName: String = "Ada Lovelace",
        bio: String = "",
        followers: CountEstimate = .unavailable,
        following: CountEstimate = .unavailable
    ) -> UserProfile {
        UserProfile(
            id: ProfileID("prof-1"),
            handle: handle,
            displayName: displayName,
            bio: bio,
            avatarURL: nil,
            websiteURL: nil,
            isVerified: false,
            followerCount: followers,
            followingCount: following
        )
    }

    @Test func prefixesHandleWithSigil() {
        let model = ProfileDisplayModel(profile: profile(handle: "ada"))
        #expect(model.handle == "@ada")
    }

    @Test func buildsMonogramFromDisplayName() {
        #expect(ProfileDisplayModel(profile: profile(displayName: "Ada Lovelace")).avatarMonogram == "AL")
        #expect(ProfileDisplayModel(profile: profile(displayName: "Cher")).avatarMonogram == "C")
        // Falls back to the handle when the display name is blank.
        #expect(ProfileDisplayModel(profile: profile(handle: "grace", displayName: "")).avatarMonogram == "G")
    }

    @Test func hidesEmptyBio() {
        #expect(ProfileDisplayModel(profile: profile(bio: "   ")).hasBio == false)
        #expect(ProfileDisplayModel(profile: profile(bio: "hi")).hasBio == true)
    }

    @Test func abbreviatesCounts() {
        #expect(ProfileDisplayModel.abbreviate(0) == "0")
        #expect(ProfileDisplayModel.abbreviate(999) == "999")
        #expect(ProfileDisplayModel.abbreviate(1_000) == "1K")
        #expect(ProfileDisplayModel.abbreviate(1_234) == "1.2K")
        #expect(ProfileDisplayModel.abbreviate(12_500) == "12.5K")
        #expect(ProfileDisplayModel.abbreviate(1_500_000) == "1.5M")
    }

    @Test func formatsCountEstimates() {
        #expect(ProfileDisplayModel.format(.exact(0)) == "0")
        #expect(ProfileDisplayModel.format(.exact(1_234)) == "1.2K")
        #expect(ProfileDisplayModel.format(.atLeast(200)) == "200+")
        #expect(ProfileDisplayModel.format(.atLeast(1_000)) == "1K+")
        #expect(ProfileDisplayModel.format(.unavailable) == "—")
    }

    @Test func distinguishesZeroFromUnavailable() {
        // A user with no followers reads "0"; an unreadable counter reads "—".
        #expect(ProfileDisplayModel(profile: profile(followers: .exact(0))).followerText == "0")
        #expect(ProfileDisplayModel(profile: profile(followers: .unavailable)).followerText == "—")
    }

    @Test func rendersMissingCountsAsDash() {
        let model = ProfileDisplayModel(profile: profile(followers: .unavailable, following: .unavailable))
        #expect(model.followerText == "—")
        #expect(model.followingText == "—")
    }

    @Test func derivesEstimateFromEdgeSample() {
        // A complete page → exact; a truncated page → "at least".
        #expect(CountEstimate.fromSample(count: 2, hasMore: false) == .exact(2))
        #expect(CountEstimate.fromSample(count: 200, hasMore: true) == .atLeast(200))
    }
}
