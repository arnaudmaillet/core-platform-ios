import CoreModels
import Foundation
import LocalStore
import Testing
import UIKit
@testable import Profile

/// The settings screens open on what the server last said (#1776), with no
/// skeleton, then revalidate in place.
@MainActor
struct SettingsCacheFirstTests {
    private final class Folder: Sendable {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SettingsCacheFirstTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private actor Location: LocationSharingManaging {
        private var offline = false
        private(set) var reads = 0
        func goOffline() { offline = true }
        func locationSharing() async throws -> LocationSharingSettings {
            reads += 1
            if offline { throw ProfileError.transport(message: "offline") }
            return LocationSharingSettings(ghost: true, cityLevel: true)
        }
        func setLocationSharing(_ settings: LocationSharingSettings) async throws {}
    }

    private let folder = Folder()

    private func launch(as viewer: LocalStoreViewer = .member(account: "acct-1", profile: "me")) throws -> SettingsLocalCache {
        SettingsLocalCache(store: try LocalStore(directory: folder.url, viewer: { viewer }))
    }

    private func settle(until condition: () async -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func aSettingsScreenOpensOnItsLastAnswerThenRevalidates() async throws {
        let manager = Location()
        let first = try launch()
        let screen = LocationSharingViewController(manager: manager).cachingSettings(in: first)
        screen.loadViewIfNeeded()
        #expect(screen.debugShownSettings == nil, "a cold device opened on settings")
        #expect(await settle { screen.debugShownSettings != nil })
        first.waitForPendingWrites()

        await manager.goOffline()
        let again = LocationSharingViewController(manager: manager).cachingSettings(in: try launch())
        again.loadViewIfNeeded()
        #expect(again.debugShownSettings == LocationSharingSettings(ghost: true, cityLevel: true), "the first frame was a skeleton")
        #expect(await settle { await manager.reads == 2 }, "the stored answer was not revalidated")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(again.debugShownSettings != nil, "a failed revalidation took the answer back")
    }

    @Test func anotherAccountReadsNoneOfThem() throws {
        let mine = try launch()
        mine.store(LocationSharingSettings(ghost: true, cityLevel: false), as: LocationSharingRecord.self, viewer: mine.viewer)
        mine.waitForPendingWrites()
        #expect(try launch(as: .member(account: "acct-2", profile: "them")).value(LocationSharingRecord.self) == nil)
    }

    @Test func everyRecordRoundTrips() throws {
        let cache = try launch()
        let privacy = ListPrivacy(followers: .mutuals, following: .onlyMe)
        cache.store(privacy, as: ListPrivacyRecord.self, viewer: cache.viewer)
        var discovery = ActivityDiscoverySettings()
        discovery.readReceipts = false
        discovery.inSuggestions = false
        cache.store(discovery, as: ActivityDiscoveryRecord.self, viewer: cache.viewer)
        var filters = CommentFilterSettings()
        filters.hiddenWords = ["spoiler"]
        filters.filtersOffensive = false
        cache.store(filters, as: CommentFiltersRecord.self, viewer: cache.viewer)
        var preferences = NotificationPreferences(
            mutedCategories: [.likes, .wallet], pausedUntil: Date().addingTimeInterval(3_600),
            quietHours: QuietHours(startMinute: 60, endMinute: 120)
        )
        preferences.emailCategories = [.messages]
        cache.store(preferences, as: NotificationPreferencesRecord.self, viewer: cache.viewer)
        let limits = LimitInteractionsViewController.State(
            limit: InteractionLimit(audience: .recentFollowers, until: Date().addingTimeInterval(86_400)),
            allowsSoundReuse: false
        )
        cache.store(limits, as: InteractionLimitsRecord.self, viewer: cache.viewer)
        cache.waitForPendingWrites()

        let relaunched = try launch()
        #expect(relaunched.value(ListPrivacyRecord.self) == privacy)
        #expect(relaunched.value(ActivityDiscoveryRecord.self) == discovery)
        #expect(relaunched.value(CommentFiltersRecord.self) == filters)
        let stored = try #require(relaunched.value(NotificationPreferencesRecord.self))
        #expect(stored.mutedCategories == [.likes, .wallet])
        #expect(stored.emailCategories == [.messages])
        #expect(stored.quietHours == QuietHours(startMinute: 60, endMinute: 120))
        #expect(stored.pausedUntil != nil)
        let storedLimits = try #require(relaunched.value(InteractionLimitsRecord.self))
        #expect(storedLimits.limit?.audience == .recentFollowers)
        #expect(!storedLimits.allowsSoundReuse)
    }

    /// A pause or a limit that ended while the app was closed opens as off.
    @Test func whatEndedWhileClosedOpensAsOff() throws {
        let cache = try launch()
        cache.store(
            NotificationPreferences(pausedUntil: Date().addingTimeInterval(-60)),
            as: NotificationPreferencesRecord.self, viewer: cache.viewer
        )
        cache.store(
            LimitInteractionsViewController.State(
                limit: InteractionLimit(audience: .nonFollowers, until: Date().addingTimeInterval(-60)), allowsSoundReuse: true
            ),
            as: InteractionLimitsRecord.self, viewer: cache.viewer
        )
        cache.waitForPendingWrites()
        #expect(cache.value(NotificationPreferencesRecord.self)?.pausedUntil == nil)
        #expect(cache.value(InteractionLimitsRecord.self)?.limit == nil)
    }
}
