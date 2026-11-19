import Foundation
import Testing
@testable import CoreStorage

/// Sign out, then in as someone else: nothing of the previous viewer is read
/// (#2376). One device — one `UserDefaults`, one `StorageScope` — driven by
/// `ViewerStorageBinding`, the very code the app runs on every viewer change,
/// with the real stores over that scope.
///
/// ⚠️ KEYED, NOT WIPED: the previous viewer's piles are all still on the
/// device, under their own keys, and come back when they do. Only the teen
/// flag, which is the device's, goes on an account change.
@MainActor
struct ViewerIsolationTests {
    private struct Device {
        let scope: StorageScope
        let binding: ViewerStorageBinding
        let bookmarks: PostBookmarkStore
        let history: PostViewHistoryStore
        let presence: SectionPresenceStore
        let sounds: SavedSoundStore
        let wallet: WalletStore
        let teen: TeenProtections
    }

    private static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ViewerIsolation.\(UUID().uuidString)"))
    }

    /// The device as the app has it at launch: one scope, unscoped until the
    /// first render, and every store over it.
    private static func device(defaults: UserDefaults) -> Device {
        let scope = StorageScope()
        let teen = TeenProtections(defaults: defaults, screenTime: ScreenTimeStore(defaults: defaults))
        return Device(
            scope: scope,
            binding: ViewerStorageBinding(scope: scope, teenProtections: teen),
            bookmarks: PostBookmarkStore(defaults: defaults, scope: scope, launchArguments: []),
            history: PostViewHistoryStore(defaults: defaults, scope: scope),
            presence: SectionPresenceStore(defaults: defaults, scope: scope),
            sounds: SavedSoundStore(defaults: defaults, scope: scope),
            wallet: WalletStore(defaults: defaults, scope: scope, launchArguments: []),
            teen: teen
        )
    }

    private static func expectNothingOfA(_ device: Device, _ moment: Comment) {
        #expect(device.bookmarks.savedPostIDs.isEmpty, moment)
        #expect(device.history.views.isEmpty, moment)
        #expect(device.presence.count(screen: "profile.a", section: "posts") == nil, moment)
        #expect(device.sounds.savedSoundIDs.isEmpty, moment)
        #expect(!device.teen.isMinor, moment)
    }

    @Test func signingOutAndInAsSomeoneElseReadsNothingOfThePreviousViewer() throws {
        let device = Self.device(defaults: try Self.defaults())

        // Member A, their profile resolved: something in every store.
        #expect(device.binding.enter(account: "A"))
        device.binding.profileResolved(account: "A", profile: "pa")
        #expect(device.scope.owner == .member(account: "A", profile: "pa"))
        device.bookmarks.toggle("a-post")
        device.history.record("a-viewed")
        device.presence.remember(3, screen: "profile.a", section: "posts")
        device.sounds.toggle("a-sound")
        device.wallet.credit(500)
        device.teen.record(account: "A", isMinor: true)
        let aBalance = device.wallet.balance
        #expect(device.bookmarks.savedPostIDs == ["a-post"])
        #expect(device.teen.isMinor)

        // Signed out: a guest, who reads none of it and holds no wallet.
        #expect(!device.binding.enter(account: nil))
        #expect(device.scope.owner == .guest)
        Self.expectNothingOfA(device, "after the sign-out")
        #expect(!device.scope.holdsWallet)

        // Member B, before their profile resolves: the profile's keys are the
        // account's meanwhile, and still nothing of A's.
        #expect(device.binding.enter(account: "B"))
        #expect(device.scope.owner == .member(account: "B", profile: nil))
        Self.expectNothingOfA(device, "B's account, profile not resolved")
        #expect(device.wallet.balance == WalletStore.Policy.seededBalance, "B's wallet is B's first one, not A's")

        // B's profile resolved: still nothing of A's, and B's writes are B's.
        device.binding.profileResolved(account: "B", profile: "pb")
        Self.expectNothingOfA(device, "B's profile resolved")
        #expect(device.wallet.balance != aBalance)
        device.bookmarks.toggle("b-post")
        #expect(device.bookmarks.savedPostIDs == ["b-post"])

        // A again: A's piles are where A left them — keyed, not wiped.
        #expect(device.binding.enter(account: "A"))
        device.binding.profileResolved(account: "A", profile: "pa")
        #expect(device.bookmarks.savedPostIDs == ["a-post"])
        #expect(device.history.views.map(\.postID) == ["a-viewed"])
        #expect(device.presence.count(screen: "profile.a", section: "posts") == 3)
        #expect(device.sounds.savedSoundIDs == ["a-sound"])
        #expect(device.wallet.balance == aBalance)
        // The teen flag is no pile: A's own account read records it again.
        #expect(!device.teen.isMinor)
    }

    /// An account to account change with no sign-out between (#2376, the
    /// owner's decision B): the previous account's teen flag goes at once,
    /// rather than holding until the new account's read records its own.
    @Test func anotherAccountWithoutASignOutIsNoTeenUntilItsOwnReadSaysSo() throws {
        let device = Self.device(defaults: try Self.defaults())
        device.binding.enter(account: "A")
        device.binding.profileResolved(account: "A", profile: "pa")
        device.teen.record(account: "A", isMinor: true)
        #expect(device.teen.isMinor)

        #expect(device.binding.enter(account: "B"))
        #expect(!device.teen.isMinor, "A's teen flag held for B")
        #expect(!device.teen.restrictsPurchases)

        device.teen.record(account: "B", isMinor: true)
        #expect(device.teen.isMinor)
    }

    /// The same account at a cold start (the scope starts unscoped on every
    /// launch): its teen flag stays, so a teen is protected from the first
    /// frame, before the account is read again.
    @Test func theSameAccountAtAColdStartKeepsItsTeenFlag() throws {
        let defaults = try Self.defaults()
        let lastLaunch = Self.device(defaults: defaults)
        lastLaunch.binding.enter(account: "A")
        lastLaunch.teen.record(account: "A", isMinor: true)

        let launch = Self.device(defaults: defaults)
        #expect(launch.scope.owner == .unscoped)
        #expect(launch.binding.enter(account: "A"))
        #expect(launch.teen.isMinor)
    }

    /// The same account again keeps the profile it resolved, and asks for no
    /// account read; a profile answered for an account that has since left
    /// changes nothing.
    @Test func theScopeMovesOnlyForTheAccountItHolds() throws {
        let device = Self.device(defaults: try Self.defaults())
        device.binding.enter(account: "A")
        device.binding.profileResolved(account: "A", profile: "pa")
        #expect(!device.binding.enter(account: "A"))
        #expect(device.scope.owner == .member(account: "A", profile: "pa"))

        device.binding.enter(account: "B")
        device.binding.profileResolved(account: "A", profile: "pa")
        #expect(device.scope.owner == .member(account: "B", profile: nil))
    }
}
