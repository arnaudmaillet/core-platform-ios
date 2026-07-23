import CoreModels
import Testing
@testable import Maps

/// What the full-list sheet renders per row, and which rows carry account
/// actions at all.
struct MapSubFilterOptionTests {
    private static func person(
        _ id: String, title: String, handle: String?
    ) -> MapSubFilterOption {
        MapSubFilterOption.people([
            MapFavorite(profileID: ProfileID(id), title: title, avatarURL: nil, handle: handle)
        ])[0]
    }

    @Test func personRowShowsFullNameOverHandle() {
        let option = Self.person("prof-0", title: "Ava Moreau", handle: "ava.moreau")
        #expect(option.sheetTitle == "Ava Moreau")
        #expect(option.sheetSubtitle == "@ava.moreau")
        // The PILL still shows only the first name — the sheet is the place
        // with room for the full identity.
        #expect(option.content.title == "Ava")
    }

    @Test func handleFallsBackToNothingRatherThanAnEmptySigil() {
        // A profile that never hydrated a handle renders as a single-line
        // row; "@" on its own would read as a broken field.
        #expect(Self.person("prof-1", title: "Kenji", handle: nil).sheetSubtitle == nil)
        #expect(Self.person("prof-2", title: "Lena", handle: "").sheetSubtitle == nil)
    }

    @Test func placeCategoriesHaveNoSubtitleAndNoAccount() {
        for option in MapSubFilterOption.placeCategories {
            #expect(option.sheetSubtitle == nil)
            // No account behind a category → no profile/mute/unfollow swipes.
            #expect(option.profileID == nil)
        }
    }

    @Test func personRowsExposeTheirProfileForSwipeActions() {
        let option = Self.person("prof-3", title: "Marcus Holt", handle: "marcus.holt")
        #expect(option.profileID == ProfileID("prof-3"))
    }
}
