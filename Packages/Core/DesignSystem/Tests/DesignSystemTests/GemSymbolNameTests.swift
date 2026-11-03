import Testing
@testable import DesignSystem

/// The currency is "Crowns" wherever the user reads or hears it (#2072), in
/// one place, with singular and plural right.
struct GemSymbolNameTests {
    @Test func theNameIsCrowns() {
        #expect(GemSymbol.name == "Crowns")
        #expect(AppSymbol.crownFilled.accessibilityLabel == "Crowns")
    }

    @Test func anAmountCountsItsCrowns() {
        #expect(GemSymbol.amount(0) == "0 crowns")
        #expect(GemSymbol.amount(1) == "1 crown")
        #expect(GemSymbol.amount(2) == "2 crowns")
        #expect(GemSymbol.amount(1_200) == "\(1_200.formatted()) crowns", "grouped as the locale does")
    }

    @Test func whatIsMissingCountsToo() {
        #expect(GemSymbol.more(1) == "1 more crown")
        #expect(GemSymbol.more(30) == "30 more crowns")
    }
}
