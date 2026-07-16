import CoreModels
import Foundation
import Testing
@testable import Profile

struct ProfileDisplayModelTests {
    private func profile(
        handle: String = "ada",
        displayName: String = "Ada Lovelace",
        bio: String = "",
        avatarURL: URL? = nil,
        followers: CountEstimate = .unavailable,
        following: CountEstimate = .unavailable,
        reactions: CountEstimate = .unavailable,
        views: CountEstimate = .unavailable
    ) -> UserProfile {
        UserProfile(
            id: ProfileID("prof-1"),
            handle: handle,
            displayName: displayName,
            bio: bio,
            avatarURL: avatarURL,
            websiteURL: nil,
            isVerified: false,
            followerCount: followers,
            followingCount: following,
            reactionCount: reactions,
            viewCount: views
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

    @Test func formatsWebsiteInstagramStyle() {
        // Scheme and "www." stripped, trailing slash trimmed, path kept.
        #expect(ProfileDisplayModel.websiteDisplay(URL(string: "https://www.ada.dev/notes/")) == "ada.dev/notes")
        #expect(ProfileDisplayModel.websiteDisplay(URL(string: "http://ada.dev")) == "ada.dev")
        #expect(ProfileDisplayModel.websiteDisplay(nil) == nil)
    }

    @Test func formatsReactionsAndViews() {
        let model = ProfileDisplayModel(profile: profile(reactions: .exact(1_234), views: .atLeast(200)))
        #expect(model.reactionsText == "1.2K")
        #expect(model.viewsText == "200+")
    }

    @Test func reactionsAndViewsReadUnavailableWhenUnprojected() {
        // Wherever counter.v1 doesn't project these metrics (the fleet, and
        // views on the mock), the band must not claim "0".
        let model = ProfileDisplayModel(profile: profile())
        #expect(model.reactionsText == "—")
        #expect(model.viewsText == "—")
    }

    @Test func bannerMirrorsAvatarUntilCoverAssetExists() {
        // profile.v1 has no cover-media field yet; the banner reuses the avatar.
        let url = URL(string: "https://cdn.example/ada.jpg")
        #expect(ProfileDisplayModel(profile: profile(avatarURL: url)).bannerImageURL == url)
        #expect(ProfileDisplayModel(profile: profile()).bannerImageURL == nil)
    }

    @Test func derivesEstimateFromEdgeSample() {
        // A complete page → exact; a truncated page → "at least".
        #expect(CountEstimate.fromSample(count: 2, hasMore: false) == .exact(2))
        #expect(CountEstimate.fromSample(count: 200, hasMore: true) == .atLeast(200))
    }
}
