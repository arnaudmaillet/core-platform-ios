import MapKit
import MapsInterface
import Testing
import UIKit
@testable import Maps

/// The unlock is the sheet's NATIVE TOOLBAR, as "Use this sound" is the sound
/// sheet's: the offer is presented as the root of a navigation controller
/// that hides its bar and shows its toolbar, and the prominent capsule fills
/// the toolbar — it is no longer in the content.
@MainActor
struct CountryUnlockToolbarTests {
    private final class FakeAccess: CountryAccess {
        let homeCountry: String? = "FR"
        let gems: Int
        init(gems: Int) { self.gems = gems }
        func isUnlocked(_ code: String) -> Bool { code == "FR" }
        func standing(of code: String) -> CountryStanding? {
            CountryStanding(code: code, rank: 4, likes: 8_700, posts: 86, price: 50)
        }
        func standings() -> [CountryStanding] { [] }
        func unlock(_ code: String) -> CountryUnlockOutcome { .unlocked(remainingGems: gems - 50) }
    }

    private func makeSheet(gems: Int = 100) throws -> (CountryUnlockSheetViewController, UINavigationController) {
        let spain = try #require(CountryAtlas.shared.country(code: "ES"))
        let sheet = CountryUnlockSheetViewController(country: spain, access: FakeAccess(gems: gems))
        let navigation = sheet.wrappedInSheet()
        sheet.loadViewIfNeeded()
        return (sheet, navigation)
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    @Test func theSheetIsANavigationControllerShowingItsToolbarNotItsBar() throws {
        let (_, navigation) = try makeSheet()
        #expect(navigation.isNavigationBarHidden)
        #expect(!navigation.isToolbarHidden)
        #expect(navigation.modalPresentationStyle == .pageSheet)
        #expect(navigation.sheetPresentationController?.detents.count == 1)
        #expect(navigation.sheetPresentationController?.prefersGrabberVisible == true)
    }

    @Test func theUnlockIsTheToolbarsOneItemAndNotInTheContent() throws {
        let (sheet, _) = try makeSheet()
        let items = try #require(sheet.toolbarItems)
        #expect(items.count == 1)
        #expect(items.first?.customView === sheet.unlockButton)
        #expect(items.first?.hidesSharedBackground == true, "a bubble in a bubble")
        #expect(sheet.unlockButton.configuration?.title == "Unlock · 50")
        #expect(!Self.descendants(of: sheet.view).contains { $0 === sheet.unlockButton },
                "the unlock is still in the content")
        #expect(sheet.unlockButton.isEnabled)
    }

    @Test func shortOfGemsTheToolbarsUnlockIsDisabled() throws {
        let (sheet, _) = try makeSheet(gems: 10)
        #expect(!sheet.unlockButton.isEnabled)
        let labels = Self.descendants(of: sheet.view).compactMap { ($0 as? UILabel)?.text }
        #expect(labels.contains("You need 40 more gems"))
    }

    /// The detent counts the toolbar: the map frames the country above the
    /// WHOLE sheet.
    @Test func theSheetsHeightIsTheContentAndTheToolbar() throws {
        let (sheet, _) = try makeSheet()
        #expect(sheet.toolbarBand > 0)
        #expect(sheet.sheetHeight == sheet.contentHeight + sheet.toolbarBand)
    }

    /// ⚠️ FROM ONE LOCKED COUNTRY STRAIGHT TO ANOTHER (#760): the open sheet
    /// takes the new country in place — header, pitch and price — instead of
    /// closing and making the user tap again.
    @Test func anotherCountryReplacesTheOfferInPlace() throws {
        let (sheet, _) = try makeSheet()
        let italy = try #require(CountryAtlas.shared.country(code: "IT"))
        sheet.show(italy)
        #expect(sheet.country.code == "IT")
        let labels = Self.descendants(of: sheet.view).compactMap { ($0 as? UILabel)?.text }
        #expect(labels.contains("Unlock \(italy.name) to see its posts on your map."), "\(labels)")
        #expect(!labels.contains { $0.contains("Spain") }, "the first country is still on show: \(labels)")
        #expect(sheet.unlockButton.configuration?.title == "Unlock · 50")
    }

    /// A country's flag disc answers its own tap: MapKit's selection of it,
    /// landing a beat later, must never reach the offer — it closed it, the
    /// zoom in and straight back out (#760).
    @Test func mapKitsSelectionOfAFlagDiscOpensNothing() throws {
        let spain = try #require(CountryAtlas.shared.country(code: "ES"))
        #expect(!MapsViewController.mapSelectionOpens(CountryFlagAnnotation(country: spain, isLocked: true, rank: 4)))
        #expect(MapsViewController.mapSelectionOpens(MKPointAnnotation()))
    }
}
