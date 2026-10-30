import Testing
@testable import Maps

// The locked guest map (#564).

@MainActor
struct GuestMapLockTests {
    /// A guest without location sees the locked showcase, whether never asked
    /// or denied; allowing location unlocks it. Members are never locked.
    @Test func theLockFollowsMembershipAndPermission() {
        #expect(MapsViewController.guestLocationLocked(isMember: false, permission: .notAsked))
        #expect(MapsViewController.guestLocationLocked(isMember: false, permission: .denied))
        #expect(!MapsViewController.guestLocationLocked(isMember: false, permission: .allowed))
        #expect(!MapsViewController.guestLocationLocked(isMember: true, permission: .notAsked))
        #expect(!MapsViewController.guestLocationLocked(isMember: true, permission: .denied))
        #expect(!MapsViewController.guestLocationLocked(isMember: true, permission: .allowed))
    }

    /// Without a locator there is no card, so no way out: never locked.
    @Test func noLocatorMeansNoLock() {
        #expect(!MapsViewController.guestLocationLocked(isMember: false, permission: nil))
    }

    /// One writer for the map's interaction, from BOTH gates: an open
    /// transition and the guest lock each make it inert on their own.
    @Test func theInteractionCombinesBothGates() {
        #expect(MapsViewController.mapIsInteractive(inert: false, guestLocked: false))
        #expect(!MapsViewController.mapIsInteractive(inert: true, guestLocked: false))
        // The guest without location moves the map since #1907, within the
        // country band (`MapDepthClamp`).
        #expect(MapsViewController.mapIsInteractive(inert: false, guestLocked: true))
        #expect(!MapsViewController.mapIsInteractive(inert: true, guestLocked: true))
    }

    /// The guest without location's way out is the bar's "Allow location"
    /// (#1907): the map shows no card for them, whatever the permission. A
    /// member with no open country keeps the card; the locate button otherwise.
    @Test func theGuestCardMovesToTheBar() {
        for permission in [LocationPermission.notAsked, .denied] {
            #expect(MapsViewController.locationControlsFace(
                permission: permission, guestLocked: true, hasNoOpenCountry: true
            ) == .none)
        }
        #expect(MapsViewController.locationControlsFace(
            permission: .notAsked, guestLocked: false, hasNoOpenCountry: true
        ) == .card(.notAsked))
        #expect(MapsViewController.locationControlsFace(
            permission: .allowed, guestLocked: false, hasNoOpenCountry: true
        ) == .button(.allowed))
        #expect(MapsViewController.locationControlsFace(
            permission: .denied, guestLocked: false, hasNoOpenCountry: false
        ) == .button(.denied))
        #expect(MapsViewController.locationControlsFace(
            permission: nil, guestLocked: false, hasNoOpenCountry: true
        ) == .none)
        #expect(MapsViewController.locationControlsFace(
            permission: .notAsked, guestLocked: false, hasNoOpenCountry: nil
        ) == .none)
    }
}
