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

    @Test func nothingIsOpenBeforeAGuestOpensIt() {
        #expect(!makeGift().isOpen)
    }

    /// A flat 50 at sign-up (#1146, the owner 2026-10-14): however long the
    /// guest browsed, nothing grows.
    @Test func signingUpCreditsAFlatFiftyOnceWhateverTheWait() {
        let gift = makeGift()
        let wallet = makeWallet()
        let before = wallet.balance
        gift.open()
        #expect(gift.isOpen)
        clock.advance(by: 30 * day)

        #expect(gift.settle(into: wallet) == WelcomeGift.Policy.firstLaunch)
        #expect(WelcomeGift.Policy.firstLaunch == 50)
        #expect(wallet.balance == before + 50)
        #expect(!gift.isOpen)

        // A sign-out and a second sign-in on this device: nothing more.
        gift.open()
        #expect(!gift.isOpen)
        #expect(gift.settle(into: wallet) == 0)
        #expect(wallet.balance == before + 50)
    }

    @Test func reopeningKeepsTheGiftOpenAcrossProcesses() {
        let gift = makeGift()
        gift.open()
        clock.advance(by: 2 * day)
        gift.open()
        // A new process on the same device reads the same gift.
        #expect(makeGift().isOpen)
    }

    @Test func aDeviceWhoseFirstViewerIsAMemberNeverOpensAGift() {
        let gift = makeGift()
        let wallet = makeWallet()
        let before = wallet.balance
        #expect(gift.settle(into: wallet) == 0)
        #expect(wallet.balance == before)
        gift.open()
        #expect(!gift.isOpen)
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
