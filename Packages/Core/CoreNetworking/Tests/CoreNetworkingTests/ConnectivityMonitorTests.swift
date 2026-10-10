import Foundation
import Testing
@testable import CoreNetworking

/// Whether the app can reach the network, and the moment it can again (#793).
/// Each test owns its monitor: the shared one is process-wide.
@MainActor
struct ConnectivityMonitorTests {
    @Test func aRecoveryIsAnnouncedOncePerOfflineToOnlineEdge() {
        let monitor = ConnectivityMonitor()
        var recoveries = 0
        let observation = monitor.onRecovery { recoveries += 1 }

        monitor.report(online: true)
        #expect(recoveries == 0, "online to online is no recovery")
        monitor.report(online: false)
        #expect(!monitor.isOnline)
        #expect(recoveries == 0)
        monitor.report(online: true)
        #expect(monitor.isOnline)
        #expect(recoveries == 1)
        monitor.report(online: true)
        #expect(recoveries == 1, "a repeated online is not a second recovery")
        withExtendedLifetime(observation) {}
    }

    @Test func aReleasedObservationHearsNothing() {
        let monitor = ConnectivityMonitor()
        var recoveries = 0
        var observation: RecoveryObservation? = monitor.onRecovery { recoveries += 1 }
        _ = observation
        observation = nil

        monitor.report(online: false)
        monitor.report(online: true)

        #expect(recoveries == 0)
    }
}
