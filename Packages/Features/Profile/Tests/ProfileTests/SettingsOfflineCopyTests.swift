import Connect
import CoreModels
import CoreNetworking
import Foundation
import Testing
@testable import Profile

/// #794: a Settings failed row ("Couldn't load … Tap to try again.") says
/// "You’re offline" when that is why the read failed. The view models used
/// to keep only a flag, so every failure read the same; a server fault
/// still keeps each row's own words.
@MainActor
struct SettingsOfflineCopyTests {
    private static let offlineRow = "You\u{2019}re offline. Tap to try again."
    /// What a real dropped connection looks like coming out of Connect.
    private static var offline: ConnectError { droppedConnection() }

    // MARK: - Loadable rows (Account, Security Checkup, Family and Teens)

    @Test func anOfflineAccountReadSaysOfflineOnItsFailedRow() async {
        let model = AccountDetailsViewModel(account: SwitchableAccount(fails: true, failure: .offline))
        await model.load()
        #expect(model.phase == .failed(message: Self.offlineRow))
    }

    @Test func aServerFaultOnTheAccountReadKeepsItsOwnWords() async {
        let model = AccountDetailsViewModel(account: SwitchableAccount(fails: true, failure: .server(code: "internal")))
        await model.load()
        #expect(model.phase == .failed(message: AccountDetailsViewModel.failureMessage))
    }

    @Test func anOfflineCheckupNamesOfflineOnItsFailedLines() async {
        let model = SecurityCheckupViewModel(
            account: SwitchableAccount(fails: true, failure: .offline),
            sessions: SwitchableSessions(count: 2, fails: true)
        )
        await model.load()
        let items = SecurityCheckup.items(
            account: model.account, sessionCount: model.sessionCount, appLockOn: true, lockMethod: "Face ID"
        )
        #expect(items.first { $0.id == "account" }?.title == Self.offlineRow)
        #expect(items.first { $0.id == "sessions" }?.title == SecurityCheckup.failedSessionsTitle)
    }

    @Test func anOfflineAgeReadSaysOfflineOnFamilyAndTeens() async {
        let offline = await FamilyAndTeensViewController.readAge { throw droppedConnection() }
        #expect(offline == .failed(message: Self.offlineRow))
        let refused = await FamilyAndTeensViewController.readAge {
            throw AccountError.transport(message: "x", failure: .server(code: "internal"))
        }
        #expect(refused == .failed(message: FamilyAndTeensViewController.failedText))
    }

    /// The retry's toast reads the kept failure, so it says what the row
    /// says rather than "Couldn't load …" under "You’re offline".
    @Test func aFailedRetryKeepsWhyForItsToast() async {
        let account = AccountDetailsViewModel(account: SwitchableAccount(fails: true, failure: .offline))
        await account.load()
        #expect(account.failure == .offline)
        #expect(FailureCopy.title(for: account.failure, fallback: "x") == "You\u{2019}re offline")

        let checkup = SecurityCheckupViewModel(account: SwitchableAccount(fails: true, failure: .offline), sessions: nil)
        #expect(await checkup.reload(.account) == false)
        #expect(checkup.failures[.account] == .offline)

        let age = TeenAgeCheck { throw droppedConnection() }
        #expect(await age.read() == false)
        #expect(age.failure == .offline)
    }

    // MARK: - Flag rows that now keep the failure

    @Test func anOfflineDataExportCheckSaysOffline() async {
        let model = DataExportViewModel(lifecycle: FailingLifecycle(error: Self.offline))
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.failure == .offline)
        #expect(DataExportViewController.statusText(for: model.phase, email: nil, failure: model.failure) == Self.offlineRow)
    }

    @Test func aServerFaultOnTheDataExportCheckKeepsItsOwnWords() async {
        let model = DataExportViewModel(lifecycle: FailingLifecycle(error: AccountError.transport(message: "x")))
        await model.load()
        #expect(DataExportViewController.statusText(for: model.phase, email: nil, failure: model.failure)
            == "Couldn't check your data download. Tap to try again.")
    }

    @Test func anOfflineSessionsReadSaysOffline() async {
        let model = SecuritySettingsViewModel(sessions: SwitchableSessions(count: 1, fails: true, failure: .offline))
        await model.load()
        #expect(model.phase == .failed)
        #expect(SecuritySettingsViewController.failedSessionsText(model.failure) == Self.offlineRow)
        #expect(SecuritySettingsViewController.failedSessionsText(.server(code: "internal"))
            == "Couldn't load your sessions. Tap to try again.")
    }

    /// The deletion footer sits over a Try Again row: the full offline
    /// sentence, not the tap form.
    @Test func anOfflineDeletionCheckSaysOfflineInItsFooter() async {
        let model = DeleteAccountViewModel(lifecycle: FailingLifecycle(error: Self.offline))
        await model.load()
        #expect(model.phase == .failed)
        #expect(DeleteAccountViewController.footer(for: model.phase, failure: model.failure) == FailureCopy.offline)
        #expect(DeleteAccountViewController.footer(for: .failed, failure: .server(code: "internal"))?
            .hasPrefix("Couldn't check whether a deletion is already pending") == true)
    }

    @Test func anOfflinePrivacySideSaysOfflineOnItsRow() async {
        let model = PrivacySectionViewModel(
            visibility: FailingVisibility(error: Self.offline), windows: FailingWindows(error: Self.offline)
        )
        await model.load()
        #expect(model.failedSides == [.postWindow])
        #expect(model.visibilityFailure == .offline)
        #expect(PrivacySectionViewController.failedText(.postWindow, failure: model.sideFailures[.postWindow])
            == Self.offlineRow)
        #expect(PrivacySectionViewController.failedText(.postWindow, failure: nil)
            == "Couldn't load who sees your older posts. Tap to try again.")
    }

    @Test func anOfflineSensitiveContentReadSaysOfflineOnWhatYouSee() async {
        let loaded = await WhatYouSeeViewController.loadSensitive(preferences: OfflinePreferences()) { false }
        #expect(loaded.phase == .failed)
        #expect(WhatYouSeeViewController.failedText(loaded.failure) == Self.offlineRow)
        #expect(WhatYouSeeViewController.interestsFailedText(.server(code: "internal"))
            == "Couldn't load your interests. Tap to try again.")
    }

    @Test func anOfflineBlockedListKeepsWhyItFailed() async {
        let model = BlockedAccountsViewModel(blocks: FailingBlocks(error: Self.offline))
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.failure == .offline)
    }

    @Test func theDecisionAndVerificationRowsSayOfflineWhenTheyAre() {
        #expect(DecisionDetailViewController.failedFooter(.offline) == FailureCopy.offline)
        #expect(DecisionDetailViewController.failedFooter(.server(code: "internal"))
            == "Couldn't load why this decision was made.")
        #expect(AccountTypeViewController.verificationRow(.failed, failure: .offline).detail == Self.offlineRow)
        #expect(AccountTypeViewController.verificationRow(.failed).detail
            == "Couldn't load your verification status. Tap to try again.")
    }
}

private func droppedConnection() -> ConnectError {
    ConnectError(code: .unavailable, message: "x", exception: URLError(.notConnectedToInternet))
}

private struct FailingLifecycle: AccountLifecycleManaging {
    let error: any Error
    func requestDeletion() async throws {}
    func requestDataExport() async throws {}
    func gdprStatus() async throws -> AccountGdprStatus { throw error }
}

private struct FailingVisibility: ProfileVisibilityManaging {
    let error: any Error
    func activeProfileIsPrivate() async throws -> Bool { throw error }
    func setActiveProfilePrivate(_ isPrivate: Bool) async throws {}
}

private struct FailingWindows: PostWindowManaging {
    let error: any Error
    func postWindow() async throws -> PostWindow { throw error }
    func setPostWindow(_ window: PostWindow) async throws {}
}

private struct FailingBlocks: BlockedAccountsManaging {
    let error: any Error
    func blockedProfiles() async throws -> [BlockedProfile] { throw error }
    func unblock(_ profileID: ProfileID) async throws {}
}

private struct OfflinePreferences: FeedPreferencesManaging {
    func sensitiveContent() async throws -> SensitiveContentLevel {
        throw droppedConnection()
    }
    func setSensitiveContent(_ level: SensitiveContentLevel) async throws {}
    func personalizedFeed() async throws -> Bool { true }
    func setPersonalizedFeed(_ isOn: Bool) async throws {}
}
