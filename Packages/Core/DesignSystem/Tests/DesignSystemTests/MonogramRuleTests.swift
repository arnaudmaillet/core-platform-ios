import Testing
@testable import DesignSystem

/// The app's one initials rule, shared so the feed's author pill, the
/// profile and the inbox cannot drift apart. Since #811 it is the ONLY one:
/// the private copies it replaced read a handle's "@" as an initial.
struct MonogramRuleTests {
    @Test func theNameGivesTheFirstTwoInitials() {
        #expect(MonogramAvatarView.monogram(name: "Zed Aldrin", handle: "zed.aldrin") == "ZA")
        #expect(MonogramAvatarView.monogram(name: "Rosa Maria Iglesias", handle: "rosa") == "RM")
        #expect(MonogramAvatarView.monogram(name: "ava moreau", handle: "") == "AM")
    }

    @Test func aSingleNameGivesOneInitial() {
        #expect(MonogramAvatarView.monogram(name: "Cher", handle: "cher") == "C")
    }

    @Test func aBlankNameFallsBackToTheHandle() {
        #expect(MonogramAvatarView.monogram(name: "  ", handle: "@you") == "Y")
        #expect(MonogramAvatarView.monogram(name: "", handle: "grace") == "G")
    }

    /// The bug the copies had (#811): someone known only by a handle got "@"
    /// as an initial.
    @Test func aHandlesSigilIsNeverAnInitial() {
        #expect(MonogramAvatarView.monogram(name: "", handle: "@grace") == "G")
        #expect(MonogramAvatarView.monogram(name: "", handle: "@") == "?")
    }

    @Test func nothingToReadIsAQuestionMark() {
        #expect(MonogramAvatarView.monogram(name: "", handle: "") == "?")
    }
}
