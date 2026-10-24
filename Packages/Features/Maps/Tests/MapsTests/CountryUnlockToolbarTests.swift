import DesignSystem
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
        func unlock(_ code: String) async -> CountryUnlockOutcome { .unlocked(remainingGems: gems - 50) }
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

    /// ⚠️ THE BAR SHOWS, FOR ITS CLOSE ITEM top-RIGHT (#1600, moved right by
    /// the owner 2026-10-22), and the content starts behind it — the sound
    /// sheet's arrangement.
    @Test func theSheetShowsItsBarForAClosingItemTopRight() throws {
        let (sheet, navigation) = try makeSheet()
        #expect(!navigation.isNavigationBarHidden)
        let close = try #require(sheet.navigationItem.rightBarButtonItem)
        #expect(close.accessibilityIdentifier == "countryUnlock.close")
        #expect(sheet.navigationItem.rightBarButtonItems?.count == 1, "something besides the close item in the bar")
        #expect(sheet.navigationItem.leftBarButtonItems?.isEmpty ?? true, "an item top-left")
    }

    @Test func theContentStartsBehindTheBar() throws {
        let (sheet, navigation) = try makeSheet()
        navigation.view.frame = CGRect(x: 0, y: 0, width: 402, height: 500)
        navigation.view.layoutIfNeeded()
        let identity = try #require(Self.descendants(of: sheet.view).first { $0 is PlaceIdentityView })
        let top = identity.convert(identity.bounds, to: sheet.view).minY
        #expect(top < navigation.navigationBar.frame.maxY, "the content was pushed below the bar (top \(top))")
    }

    @Test func theSheetIsANavigationControllerShowingItsToolbar() throws {
        let (_, navigation) = try makeSheet()
        #expect(!navigation.isToolbarHidden)
        #expect(navigation.modalPresentationStyle == .pageSheet)
        #expect(navigation.sheetPresentationController?.detents.count == 1)
        #expect(navigation.sheetPresentationController?.prefersGrabberVisible == true)
    }

    @Test func theUnlockIsTheToolbarsOneItemAndNotInTheContent() throws {
        let (sheet, _) = try makeSheet()
        let items = try #require(sheet.toolbarItems)
        let unlock = try #require(sheet.unlockControl)
        #expect(items.count == 1)
        #expect(items.first?.customView === unlock)
        // The bar contract (#1679): the bar draws its bubble, prominent.
        #expect(items.first?.hidesSharedBackground == false, "the unlock draws a glass of its own")
        #expect(items.first?.style == .prominent)
        #expect(items.first?.identifier == "countryUnlock.unlock")
        #expect(unlock.title == "Unlock · 50")
        #expect(unlock.image != nil, "the gem left the unlock")
        #expect(!Self.descendants(of: sheet.view).contains { $0 === unlock },
                "the unlock is still in the content")
        #expect(unlock.isEnabled)
    }

    @Test func shortOfGemsTheToolbarsUnlockIsDisabled() throws {
        let (sheet, _) = try makeSheet(gems: 10)
        let unlock = try #require(sheet.unlockControl)
        #expect(!unlock.isEnabled)
        #expect(unlock.accessibilityTraits.contains(.notEnabled))
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
        #expect(sheet.unlockControl?.title == "Unlock · 50")
        #expect(sheet.toolbarItems?.first?.identifier == "countryUnlock.unlock")
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
