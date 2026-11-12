import Testing
@testable import Maps

/// A country's counts read as everywhere else (#2390): the app's one rule,
/// truncating — a country's 1,999 likes are "1.9K", never "2.0K".
struct CountryStandingCompactTests {
    @Test func itTruncatesAsTheAppDoes() {
        #expect(CountryStanding.compact(860) == "860")
        #expect(CountryStanding.compact(1_000) == "1K")
        #expect(CountryStanding.compact(1_999) == "1.9K")
        #expect(CountryStanding.compact(12_450) == "12.4K")
        #expect(CountryStanding.compact(999_999) == "999.9K")
        #expect(CountryStanding.compact(3_150_000) == "3.1M")
    }
}
