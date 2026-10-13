import Foundation
import Testing
@testable import Profile

/// The contract's normalization and hashing for Find Friends from Contacts
/// (#412, backend #806): emails lower-cased and trimmed, phones in E.164,
/// each SHA-256 over its UTF-8 bytes.
struct ContactIdentifiersTests {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test func anEmailIsLowerCasedAndTrimmed() {
        #expect(ContactIdentifiers.normalizedEmail("  John-Appleseed@Mac.com \n") == "john-appleseed@mac.com")
        #expect(ContactIdentifiers.normalizedEmail("not an email") == nil)
        #expect(ContactIdentifiers.normalizedEmail("@mac.com") == nil)
        #expect(ContactIdentifiers.normalizedEmail("kate@") == nil)
        #expect(ContactIdentifiers.normalizedEmail("kate bell@mac.com") == nil)
    }

    @Test func aNumberWithItsCountryCodeIsKeptWhateverTheRegion() {
        #expect(ContactIdentifiers.normalizedPhone("+33 6 12 34 56 78", region: nil) == "+33612345678")
        #expect(ContactIdentifiers.normalizedPhone("0033 6 12 34 56 78", region: "US") == "+33612345678")
        #expect(ContactIdentifiers.normalizedPhone("011 33 6 12 34 56 78", region: "US") == "+33612345678")
        #expect(ContactIdentifiers.normalizedPhone("+1 (555) 610-6679", region: "FR") == "+15556106679")
        #expect(ContactIdentifiers.normalizedPhone("+33 (0)6 12 34 56 78", region: nil) == "+33612345678")
    }

    @Test func aNationalNumberIsReadInTheDevicesRegion() {
        #expect(ContactIdentifiers.normalizedPhone("06 12 34 56 78", region: "FR") == "+33612345678")
        #expect(ContactIdentifiers.normalizedPhone("6 12 34 56 78", region: "FR") == "+33612345678")
        #expect(ContactIdentifiers.normalizedPhone("(555) 610-6679", region: "US") == "+15556106679")
        #expect(ContactIdentifiers.normalizedPhone("1-555-610-6679", region: "us") == "+15556106679")
        #expect(ContactIdentifiers.normalizedPhone("020 7946 0958", region: "GB") == "+442079460958")
        // Italy keeps its leading zero in E.164.
        #expect(ContactIdentifiers.normalizedPhone("06 1234 5678", region: "IT") == "+390612345678")
        #expect(ContactIdentifiers.normalizedPhone("555-610-6679 ext. 12", region: "US") == "+15556106679")
    }

    /// A guessed country code would only ever hash someone else's number.
    @Test func aNumberThatCantBeReadWithCertaintyIsSkipped() {
        #expect(ContactIdentifiers.normalizedPhone("555-610-6679", region: "FR") == nil)
        #expect(ContactIdentifiers.normalizedPhone("06 12 34 56 78", region: nil) == nil)
        #expect(ContactIdentifiers.normalizedPhone("06 12 34 56 78", region: "ZZ") == nil)
        #expect(ContactIdentifiers.normalizedPhone("0 12 34", region: "FR") == nil)
        #expect(ContactIdentifiers.normalizedPhone("+1 234", region: nil) == nil)
        #expect(ContactIdentifiers.normalizedPhone("+1234567890123456", region: nil) == nil)
        #expect(ContactIdentifiers.normalizedPhone("", region: "FR") == nil)
    }

    @Test func theHashIsSHA256OfTheNormalizedUTF8() {
        let email = ContactIdentifiers.hash("kate-bell@mac.com")
        #expect(email.count == 32)
        #expect(hex(email) == "27049386e228004504a34fe9b454c1bc82c36f1fc6ea2c0c60abfff7829ef0a1")
        #expect(hex(ContactIdentifiers.hash("+33612345678")) == "42d573cfc315801d4cd8eddd5416b416a0bf298b9b9e12d6b07442c91db42bd8")
    }

    /// Duplicates go once, and a large book is cut into calls the contract
    /// takes: at most 1000 hashes each, emails and phones together.
    @Test func aLargeBookIsSentInPagesOfAtMostAThousand() {
        let entries: [ContactEntry] = (0..<1_300).map { index in
            ContactEntry(name: "Contact \(index)", emails: ["c\(index)@example.com", "C\(index)@Example.com"], phones: index < 400 ? ["+3361234\(String(format: "%04d", index))"] : [])
        }
        let hashes = ContactHashes(entries, region: "FR")
        #expect(hashes.emails.count == 1_300)
        #expect(hashes.phones.count == 400)
        let pages = hashes.pages(of: ContactLookupLimits.maxHashesPerCall)
        #expect(pages.count == 2)
        #expect(pages.allSatisfy { $0.emails.count + $0.phones.count <= 1_000 })
        #expect(pages.reduce(0) { $0 + $1.emails.count + $1.phones.count } == 1_700)
        #expect(hashes.names[ContactIdentifiers.hash("c7@example.com")] == "Contact 7")
    }
}
