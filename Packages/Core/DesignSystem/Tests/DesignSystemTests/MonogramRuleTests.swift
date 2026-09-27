import Testing
@testable import DesignSystem

/// The app's one initials rule, shared so the feed's author pill, the
/// profile and the inbox cannot drift apart.
struct MonogramRuleTests {
    @Test func theNameGivesTheFirstTwoInitials() {
        #expect(MonogramAvatarView.monogram(name: "Zed Aldrin", handle: "zed.aldrin") == "ZA")
        #expect(MonogramAvatarView.monogram(name: "Rosa Maria Iglesias", handle: "rosa") == "RM")
    }

    @Test func aBlankNameFallsBackToTheHandle() {
        #expect(MonogramAvatarView.monogram(name: "  ", handle: "@you") == "Y")
    }

    @Test func nothingToReadIsAQuestionMark() {
        #expect(MonogramAvatarView.monogram(name: "", handle: "") == "?")
    }
}
