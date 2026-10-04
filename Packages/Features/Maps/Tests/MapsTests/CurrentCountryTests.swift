import CoreLocation
import Testing
import UIKit
@testable import Maps

/// Guest mode §3.1: the country the device is in opens for free, and with
/// location off a guest has nothing open — the card's moment.
@MainActor
struct CurrentCountryTests {

    @Test func authorizationReadsAsThreePermissions() {
        #expect(CurrentCountryProvider.permission(for: .notDetermined) == .notAsked)
        #expect(CurrentCountryProvider.permission(for: .authorizedWhenInUse) == .allowed)
        #expect(CurrentCountryProvider.permission(for: .authorizedAlways) == .allowed)
        #expect(CurrentCountryProvider.permission(for: .denied) == .denied)
        #expect(CurrentCountryProvider.permission(for: .restricted) == .denied)
    }

    @Test func aGuestWithoutLocationHasNothingOpen() {
        #expect(Access(home: nil, current: nil).hasNoOpenCountry)
    }

    @Test func theDevicesCountryIsOpenEnough() {
        #expect(!Access(home: nil, current: "ES").hasNoOpenCountry)
    }

    @Test func aMembersHomeIsOpenEnough() {
        #expect(!Access(home: "FR", current: nil).hasNoOpenCountry)
    }

    @Test func aPurchaseIsOpenEnough() {
        #expect(!Access(home: nil, current: nil, purchased: ["JP"]).hasNoOpenCountry)
    }

    @Test func aConformerWithoutLocationHasNoCurrentCountry() {
        let access: any CountryAccess = NoLocationAccess()
        #expect(access.currentCountry == nil)
    }

    @Test func theRowShowsOneFaceAtATime() {
        let row = MapLocationControlsView(frame: CGRect(x: 0, y: 0, width: 402, height: 80))
        #expect(row.isHidden, "no locator, nothing shown")

        row.apply(.card(.notAsked))
        #expect(!row.isHidden)
        #expect(row.face == .card(.notAsked))

        row.apply(.button(.allowed))
        #expect(row.face == .button(.allowed))

        row.apply(.none)
        #expect(row.isHidden)
    }

    @Test func theRowOutsideItsButtonIsTheMaps() {
        let row = MapLocationControlsView(frame: CGRect(x: 0, y: 0, width: 402, height: 44))
        row.apply(.button(.notAsked))
        row.layoutIfNeeded()
        // The leading half of the row holds nothing but map.
        #expect(row.hitTest(CGPoint(x: 40, y: 22), with: nil) == nil)
        #expect(row.hitTest(CGPoint(x: 402 - 16 - 22, y: 22), with: nil) != nil, "the button takes its own taps")
    }

    @Test func tappingReportsThePermissionShown() {
        let row = MapLocationControlsView(frame: CGRect(x: 0, y: 0, width: 402, height: 80))
        var reported: LocationPermission?
        row.onTap = { reported = $0 }
        row.apply(.card(.denied))
        row.layoutIfNeeded()
        let card = row.hitTest(CGPoint(x: 201, y: 40), with: nil) as? UIButton
        card?.sendActions(for: .primaryActionTriggered)
        #expect(reported == .denied)
    }

    private final class Access: CountryAccess {
        let homeCountry: String?
        let currentCountry: String?
        let purchased: Set<String>
        let gems = 0
        init(home: String?, current: String?, purchased: Set<String> = []) {
            homeCountry = home
            currentCountry = current
            self.purchased = purchased
        }
        func isUnlocked(_ code: String) -> Bool {
            code == homeCountry || code == currentCountry || purchased.contains(code)
        }
        func standing(of code: String) -> CountryStanding? { nil }
        func standings() -> [CountryStanding] {
            ["FR", "ES", "JP"].enumerated().map { CountryStanding(code: $1, rank: $0 + 1, likes: 1, posts: 1, price: 15) }
        }
        func unlock(_ code: String) -> CountryUnlockOutcome { .unknownCountry }
    }

    private final class NoLocationAccess: CountryAccess {
        let homeCountry: String? = "FR"
        let gems = 0
        func isUnlocked(_ code: String) -> Bool { code == "FR" }
        func standing(of code: String) -> CountryStanding? { nil }
        func standings() -> [CountryStanding] { [] }
        func unlock(_ code: String) -> CountryUnlockOutcome { .unknownCountry }
    }
}
