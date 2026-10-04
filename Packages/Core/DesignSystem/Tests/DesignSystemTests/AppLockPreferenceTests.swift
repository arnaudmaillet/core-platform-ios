import Foundation
import Testing
@testable import DesignSystem

/// Settings → Security and Login → App Lock (#418): when returning to the app
/// asks for Face ID / the passcode.
@MainActor
@Suite(.serialized)
struct AppLockPreferenceTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func offByDefaultAndStored() {
        let previous = AppLockPreference.defaults
        defer { AppLockPreference.defaults = previous }
        AppLockPreference.defaults = UserDefaults(suiteName: "lock-\(UUID().uuidString)")!
        #expect(!AppLockPreference.isOn)
        #expect(AppLockPreference.delay == .immediately)
        AppLockPreference.isOn = true
        AppLockPreference.delay = .fifteenMinutes
        #expect(AppLockPreference.isOn)
        #expect(AppLockPreference.delay == .fifteenMinutes)
    }

    @Test func offNeverLocks() {
        #expect(!AppLockPreference.shouldLock(isOn: false, backgroundedAt: nil, now: now, delay: .immediately))
        #expect(!AppLockPreference.shouldLock(isOn: false, backgroundedAt: now.addingTimeInterval(-3600), now: now, delay: .immediately))
    }

    /// A cold launch has no background time: it always locks.
    @Test func aColdLaunchLocks() {
        #expect(AppLockPreference.shouldLock(isOn: true, backgroundedAt: nil, now: now, delay: .fifteenMinutes))
    }

    @Test func returningLocksOnlyOnceTheDelayHasPassed() {
        func away(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        #expect(AppLockPreference.shouldLock(isOn: true, backgroundedAt: away(0), now: now, delay: .immediately))
        #expect(!AppLockPreference.shouldLock(isOn: true, backgroundedAt: away(59), now: now, delay: .oneMinute))
        #expect(AppLockPreference.shouldLock(isOn: true, backgroundedAt: away(60), now: now, delay: .oneMinute))
        #expect(!AppLockPreference.shouldLock(isOn: true, backgroundedAt: away(899), now: now, delay: .fifteenMinutes))
        #expect(AppLockPreference.shouldLock(isOn: true, backgroundedAt: away(900), now: now, delay: .fifteenMinutes))
    }

    /// An unknown stored delay falls back to the strictest one.
    @Test func anUnknownStoredDelayIsImmediately() {
        let previous = AppLockPreference.defaults
        defer { AppLockPreference.defaults = previous }
        AppLockPreference.defaults = UserDefaults(suiteName: "lock-\(UUID().uuidString)")!
        AppLockPreference.defaults.set(42, forKey: AppLockPreference.delayKey)
        #expect(AppLockPreference.delay == .immediately)
    }
}
