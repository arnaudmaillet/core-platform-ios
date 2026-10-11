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

    /// Search's Recent stores `displayName ?? handle` as the name, so a
    /// handle can arrive on the NAME side and must read the same.
    @Test func aSigilInTheNameIsNeverAnInitialEither() {
        #expect(MonogramAvatarView.monogram(name: "@grace", handle: "") == "G")
        #expect(MonogramAvatarView.monogram(name: "@", handle: "zed") == "Z")
        #expect(MonogramAvatarView.monogram(name: " @ ", handle: "") == "?")
    }

    @Test func nothingToReadIsAQuestionMark() {
        #expect(MonogramAvatarView.monogram(name: "", handle: "") == "?")
    }

    // MARK: - The two twists, read through the same rule (#811)

    /// The followers/following lists break words on "." and "_" as well.
    @Test func extraSeparatorsSplitAHandleIntoWords() {
        let separators: Set<Character> = [".", "_"]
        #expect(MonogramAvatarView.monogram(name: "", handle: "lena_klein", splittingOn: separators) == "LK")
        #expect(MonogramAvatarView.monogram(name: "", handle: "ana.maria", splittingOn: separators) == "AM")
        #expect(MonogramAvatarView.monogram(name: "", handle: "solo", splittingOn: separators) == "S")
    }

    @Test func extraSeparatorsStillNeverReadTheSigil() {
        let separators: Set<Character> = [".", "_"]
        #expect(MonogramAvatarView.monogram(name: "", handle: "@lena_klein", splittingOn: separators) == "LK")
        #expect(MonogramAvatarView.monogram(name: "", handle: "@zed", splittingOn: separators) == "Z")
        #expect(MonogramAvatarView.monogram(name: "", handle: "@", splittingOn: separators) == "?")
    }

    @Test func extraSeparatorsLeaveANameWithoutThemAlone() {
        let separators: Set<Character> = [".", "_"]
        #expect(MonogramAvatarView.monogram(name: "Ava Moreau", handle: "ava_m", splittingOn: separators) == "AM")
        #expect(MonogramAvatarView.monogram(name: "Cher", handle: "cher_x", splittingOn: separators) == "C")
    }

    /// The share sheet's quick targets hold one letter.
    @Test func maxLettersOneKeepsTheFirstInitialOnly() {
        #expect(MonogramAvatarView.monogram(name: "Ava Moreau", handle: "", maxLetters: 1) == "A")
        #expect(MonogramAvatarView.monogram(name: "cher", handle: "", maxLetters: 1) == "C")
        #expect(MonogramAvatarView.monogram(name: "@grace hopper", handle: "", maxLetters: 1) == "G")
        #expect(MonogramAvatarView.monogram(name: "", handle: "", maxLetters: 1) == "?")
    }

    @Test func maxLettersNeverDropsBelowOne() {
        #expect(MonogramAvatarView.monogram(name: "Ava Moreau", handle: "", maxLetters: 0) == "A")
    }

    /// Without the options the rule is exactly what it was: a "." or "_"
    /// is part of a word, and two initials at most.
    @Test func theDefaultsAreTheRuleUnchanged() {
        #expect(MonogramAvatarView.monogram(name: "", handle: "lena_klein") == "L")
        #expect(MonogramAvatarView.monogram(name: "", handle: "zed.aldrin") == "Z")
        #expect(MonogramAvatarView.monogram(name: "Rosa Maria Iglesias", handle: "rosa") == "RM")
        #expect(
            MonogramAvatarView.monogram(name: "Rosa Maria Iglesias", handle: "rosa")
                == MonogramAvatarView.monogram(name: "Rosa Maria Iglesias", handle: "rosa", splittingOn: [], maxLetters: 2)
        )
    }
}
