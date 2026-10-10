import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
import UserNotifications
@testable import Profile

/// Settings → Notifications (#392, backend #725), over the mock.
@MainActor
struct NotificationPreferencesTests {
    private struct Viewer: ProfileViewerResolving {
        func viewerProfileID() async -> ProfileID? { ProfileID(MockSocialDataset.viewerProfileID) }
    }

    private func makeRepository() -> NotificationPreferencesRepository {
        let bff = MockBFF()
        MockNotificationService(dataset: MockSocialDataset()).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return NotificationPreferencesRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: client),
            viewer: Viewer()
        )
    }

    // MARK: - Layout (no jumps, charter P8)

    /// The permission row's slot is in the first snapshot, before iOS has
    /// answered, and stays one row whatever the answer: reading the
    /// permission never inserts a row above the list or takes one away.
    @Test func thePermissionSlotIsThereFromTheFirstFrame() {
        let first = NotificationSettingsViewController.layout(permission: nil, phase: .loading)
        #expect(first.first?.0 == .system)
        #expect(first.first?.1 == [.permissionPending])

        let answers: [(UNAuthorizationStatus, NotificationSettingsViewController.Item)] = [
            (.notDetermined, .allow), (.denied, .turnOnInSettings), (.authorized, .allowed), (.provisional, .allowed)
        ]
        for (status, row) in answers {
            let layout = NotificationSettingsViewController.layout(permission: status, phase: .loading)
            #expect(layout.map(\.0) == first.map(\.0), "\(status.rawValue)")
            #expect(layout.first?.1 == [row], "\(status.rawValue)")
        }
    }

    /// While the preferences load, Pause All and every push category are
    /// bones in their own places — no "Loading…" text row.
    @Test func thePreferencesOpenOnBonesInTheirPlaces() {
        let loading = NotificationSettingsViewController.layout(permission: .authorized, phase: .loading)
        let loaded = NotificationSettingsViewController.layout(permission: .authorized, phase: .loaded(NotificationPreferences()))
        #expect(loading.map(\.0) == [.system, .pause, .push])
        #expect(Array(loaded.map(\.0).prefix(3)) == [.system, .pause, .push])
        for index in 1..<3 {
            #expect(loading[index].1.count == loaded[index].1.count, "bones stand in for rows one for one")
            #expect(loading[index].1.allSatisfy { if case .skeleton = $0 { true } else { false } })
        }
    }

    /// Every push on by default; one category off touches only it.
    @Test func aCategoryTurnsOffAlone() async throws {
        let repository = makeRepository()
        #expect(try await repository.notificationPreferences() == NotificationPreferences())

        let next = try await repository.updateNotificationPreferences(.push(.likes, false))
        #expect(next.mutedCategories == [.likes])
        #expect(try await repository.notificationPreferences().mutedCategories == [.likes])

        _ = try await repository.updateNotificationPreferences(.push(.likes, true))
        #expect(try await repository.notificationPreferences().mutedCategories.isEmpty)
    }

    /// A pause runs until it ends or is resumed; more than 8 h is refused.
    @Test func aPauseHoldsUntilResumed() async throws {
        let repository = makeRepository()
        let until = Date().addingTimeInterval(3_600)
        let paused = try await repository.updateNotificationPreferences(.pause(until: until))
        #expect(abs((paused.pausedUntil ?? .distantPast).timeIntervalSince(until)) < 1)

        await #expect(throws: (any Error).self) {
            _ = try await repository.updateNotificationPreferences(.pause(until: Date().addingTimeInterval(9 * 3_600)))
        }

        #expect(try await repository.updateNotificationPreferences(.pause(until: nil)).pausedUntil == nil)
    }

    /// Quiet hours, wrapping midnight, on and off.
    @Test func quietHoursRoundTrip() async throws {
        let repository = makeRepository()
        let hours = QuietHours(startMinute: 23 * 60, endMinute: 6 * 60 + 30)
        #expect(try await repository.updateNotificationPreferences(.quietHours(hours)).quietHours == hours)
        #expect(try await repository.updateNotificationPreferences(.quietHours(nil)).quietHours == nil)
    }

    @Test func theScreenReadsPlainly() {
        #expect(NotificationSettingsViewController.pauseChoices.last?.minutes == 480)
        #expect(NotificationCategory.allCases.count == 9)
        #expect(!NotificationSettingsViewController.timeText(minutes: 22 * 60).isEmpty)
    }
}
