import Testing
@testable import Auth

struct IdentifierValidatorsTests {
    @Test func emailsNormalizeByTrimming() {
        #expect(EmailAddress.normalize(" user@example.com ") == "user@example.com")
        #expect(EmailAddress.normalize("arnaud@core-platform.dev") == "arnaud@core-platform.dev")
    }

    @Test func bareUsernamesAreAcceptedAsEmailIdentifiers() {
        // The IdP authenticates bare usernames (BACKEND_GAPS §6).
        #expect(EmailAddress.normalize("demo") == "demo")
        #expect(EmailAddress.normalize("alice42") == "alice42")
    }

    @Test func malformedEmailsAreRejected() {
        #expect(EmailAddress.normalize("") == nil)
        #expect(EmailAddress.normalize("   ") == nil)
        #expect(EmailAddress.normalize("two words") == nil)
        #expect(EmailAddress.normalize("@example.com") == nil)
        #expect(EmailAddress.normalize("user@") == nil)
        #expect(EmailAddress.normalize("user@nodot") == nil)
        #expect(EmailAddress.normalize("user@.com") == nil)
        #expect(EmailAddress.normalize("user@domain.") == nil)
        #expect(EmailAddress.normalize("user@a@b.com") == nil)
    }

}

struct CountryDialCodeTests {
    private let france = CountryDialCode.all.first { $0.id == "FR" }!
    private let unitedStates = CountryDialCode.all.first { $0.id == "US" }!

    @Test func formattingGroupsDigitsPerCountryPattern() {
        #expect(france.format("612345678") == "6 12 34 56 78")
        #expect(unitedStates.format("5551234567") == "555 123 4567")
    }

    @Test func formattingHandlesPartialInputWhileTyping() {
        #expect(france.format("") == "")
        #expect(france.format("6") == "6")
        #expect(france.format("61") == "6 1")
        #expect(france.format("6123") == "6 12 3")
    }

    @Test func overflowDigitsTrailAsOneGroup() {
        // Callers cap input, but the formatter stays total.
        #expect(unitedStates.format("555123456789") == "555 123 4567 89")
    }

    @Test func validationFollowsNationalBounds() {
        #expect(!france.isValidNationalNumber("61234567"))   // 8: too short
        #expect(france.isValidNationalNumber("612345678"))   // 9: exact
        #expect(!france.isValidNationalNumber("6123456789")) // 10: too long
    }

    @Test func e164JoinsPrefixAndDigits() {
        #expect(france.e164("612345678") == "+33612345678")
        #expect(unitedStates.e164("5551234567") == "+15551234567")
    }
}
