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
        #expect(!MapsViewController.mapIsInteractive(inert: false, guestLocked: true))
        #expect(!MapsViewController.mapIsInteractive(inert: true, guestLocked: true))
    }
}
