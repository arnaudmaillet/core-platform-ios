import Foundation
import Testing
@testable import CoreStorage

/// Own suite-named defaults per test: the runner is parallel.
private func makeDefaults() -> UserDefaults {
    let name = "welcome-gift-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private let epoch = Date(timeIntervalSince1970: 1_755_000_000)
private let day: TimeInterval = 86_400

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

struct WelcomeGiftTests {
    private let defaults = makeDefaults()
    private let clock = Clock(epoch)

    private func makeGift() -> WelcomeGift {
        WelcomeGift(defaults: defaults, now: { [clock] in clock.now })
    }

    private func makeWallet() -> WalletStore {
        WalletStore(defaults: defaults, now: { [clock] in clock.now })
    }

    @Test func nothingIsLockedBeforeAGuestOpensIt() {
        let gift = makeGift()
        #expect(gift.lockedAmount == nil)
        #expect(gift.nextGrowthAt == nil)
    }

    @Test func aGuestStartsWithFiftyThenGainsTheClaimAmountForThreeDays() {
        let gift = makeGift()
        gift.open()
        #expect(gift.lockedAmount == 50)
        #expect(gift.nextGrowthAt == epoch.addingTimeInterval(day))

        clock.advance(by: day - 1)
        #expect(gift.lockedAmount == 50, "a day is 24 hours waited, not a midnight crossed")
        clock.advance(by: 1)
        #expect(gift.lockedAmount == 50 + WalletStore.Policy.baseClaimAmount)

        clock.advance(by: 2 * day)
        #expect(gift.lockedAmount == 125)
        #expect(gift.nextGrowthAt == nil, "the pile stops after the third day")

        clock.advance(by: 30 * day)
        #expect(gift.lockedAmount == WelcomeGift.Policy.maximum, "and never expires")
    }

    @Test func reopeningKeepsTheFirstLaunchDate() {
        let gift = makeGift()
        gift.open()
        clock.advance(by: 2 * day)
        gift.open()
        #expect(gift.lockedAmount == 100)
        // A new process on the same device reads the same gift.
        #expect(makeGift().lockedAmount == 100)
    }

    @Test func signingUpCreditsThePileOnce() {
        let gift = makeGift()
        let wallet = makeWallet()
        let before = wallet.balance
        gift.open()
        clock.advance(by: day)

        #expect(gift.settle(into: wallet) == 75)
        #expect(wallet.balance == before + 75)
        #expect(gift.lockedAmount == nil)

        // A sign-out and a second sign-in on this device: nothing more.
        gift.open()
        #expect(gift.lockedAmount == nil)
        #expect(gift.settle(into: wallet) == 0)
        #expect(wallet.balance == before + 75)
    }

    @Test func aDeviceWhoseFirstViewerIsAMemberNeverOpensAGift() {
        let gift = makeGift()
        let wallet = makeWallet()
        let before = wallet.balance
        #expect(gift.settle(into: wallet) == 0)
        #expect(wallet.balance == before)
        gift.open()
        #expect(gift.lockedAmount == nil)
    }

    @Test func creditCountsAsEarnedAndLeavesTheClaimAlone() {
        let wallet = makeWallet()
        let before = wallet.snapshot()
        wallet.credit(40)
        let after = wallet.snapshot()
        #expect(after.balance == before.balance + 40)
        #expect(after.claimAvailable == before.claimAvailable)
        wallet.credit(0)
        wallet.credit(-5)
        #expect(wallet.balance == after.balance)
    }
}
