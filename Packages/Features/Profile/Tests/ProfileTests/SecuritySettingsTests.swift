import CoreContracts
import DesignSystem
import Foundation
import Testing
import UIKit
@testable import Profile

/// Settings → Security and Login (#384): how a session's device is named, the
/// order sessions are listed in, and what revoking does to the list.
@MainActor
struct SecuritySettingsTests {
    // MARK: - Device names

    @Test func thisAppsOwnUserAgentNamesModelAndSystem() {
        let device = SessionDevice(userAgent: "core-platform-ios/1.0 (iPhone; iOS 27.0)")
        #expect(device == SessionDevice(kind: .iPhone, title: "iPhone", detail: "iOS 27.0"))
        #expect(SessionDevice(userAgent: "core-platform-ios/1.0 (iPad; iPadOS 26.4)").kind == .iPad)
    }

    /// The app's old bare user agent (before it carried model and system)
    /// still reads as this app on an iPhone, not as an unknown device.
    @Test func theBareAppUserAgentIsStillAnIPhone() {
        #expect(SessionDevice(userAgent: "core-platform-ios") == SessionDevice(kind: .iPhone, title: "iPhone", detail: nil))
    }

    @Test func browsersAreNamedByPlatform() {
        let mac = SessionDevice(userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_6) Safari/605.1.15")
        #expect(mac == SessionDevice(kind: .mac, title: "Mac", detail: "Web browser"))
        #expect(SessionDevice(userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)").kind == .windows)
        #expect(SessionDevice(userAgent: "Mozilla/5.0 (Linux; Android 15)").kind == .android)
        #expect(SessionDevice(userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)").detail == "Web browser")
    }

    /// Nothing recognisable is an unknown device, never a guess.
    @Test func anythingElseIsUnknown() {
        #expect(SessionDevice(userAgent: "") == SessionDevice(kind: .unknown, title: "Unknown device", detail: nil))
        #expect(SessionDevice(userAgent: "curl/8.7").kind == .unknown)
    }

    // MARK: - Listing

    @Test func currentFirstThenNewestAndOnlyActive() {
        func view(_ id: String, current: Bool = false, status: Auth_V1_SessionStatus = .active, seconds: Int64) -> Auth_V1_SessionView {
            var view = Auth_V1_SessionView()
            view.sessionID = id
            view.current = current
            view.status = status
            view.issuedAt.seconds = seconds
            return view
        }
        let sessions = AccountSessionsRepository.sessions(from: [
            view("old", seconds: 100),
            view("revoked", status: .revoked, seconds: 900),
            view("me", current: true, seconds: 50),
            view("new", seconds: 500),
            view("expired", status: .expired, seconds: 800)
        ])
        #expect(sessions.map(\.id) == ["me", "new", "old"])
        #expect(sessions.first?.signedInAt == Date(timeIntervalSince1970: 50))
    }

    @Test func theCurrentSessionSaysThisDevice() {
        let current = AccountSession(id: "a", device: SessionDevice(userAgent: "core-platform-ios/1.0 (iPhone; iOS 27.0)"), isCurrent: true, signedInAt: nil)
        #expect(SecuritySettingsViewController.sessionSubtitle(current) == "iOS 27.0 · This device")
        let other = AccountSession(id: "b", device: SessionDevice(userAgent: ""), isCurrent: false, signedInAt: nil)
        #expect(SecuritySettingsViewController.sessionSubtitle(other) == "")
    }

    // MARK: - View model

    @Test func revokingDropsOnlyThatRow() async throws {
        let stub = StubSessions()
        let model = SecuritySettingsViewModel(sessions: stub)
        await model.load()
        guard case .loaded(let before) = model.phase else { Issue.record("not loaded"); return }
        try await model.revoke(before[1])
        #expect(await stub.revoked == ["ipad"])
        #expect(model.phase == .loaded([before[0]]))
    }

    /// A failed revoke throws and leaves the row: the list never shows a
    /// device as gone while the server still has it.
    @Test func aFailedRevokeKeepsTheRow() async {
        let stub = StubSessions(failsRevoke: true)
        let model = SecuritySettingsViewModel(sessions: stub)
        await model.load()
        guard case .loaded(let before) = model.phase else { Issue.record("not loaded"); return }
        await #expect(throws: (any Error).self) { try await model.revoke(before[1]) }
        #expect(model.phase == .loaded(before))
    }

    @Test func aFailedLoadCanBeRetried() async {
        let stub = StubSessions(failsList: true)
        let model = SecuritySettingsViewModel(sessions: stub)
        await model.load()
        #expect(model.phase == .failed)
        await stub.setFailsList(false)
        await model.load()
        guard case .loaded(let sessions) = model.phase else { Issue.record("not loaded"); return }
        #expect(sessions.count == 2)
    }

    /// The sessions section opens on bones shaped like sessions, never a
    /// spinner row (charter P8), and the model goes from loading straight to
    /// the list, with no phase in between.
    @Test func theSessionsOpenOnBonesThenTheListWithNothingInBetween() async {
        let items = SecuritySettingsViewController.sessionItems(for: .loading)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { if case .skeleton = $0 { true } else { false } })

        let model = SecuritySettingsViewModel(sessions: StubSessions())
        var phases: [SecuritySettingsViewModel.Phase] = []
        model.onChange = { phases.append(model.phase) }
        await model.load()
        #expect(phases.count == 1)
        guard case .loaded(let sessions)? = phases.first else { Issue.record("expected the list, got \(phases)"); return }
        #expect(SecuritySettingsViewController.sessionItems(for: model.phase) == sessions.map { .session($0) })
    }

    /// A skeleton row lays one bone over each part of the row it stands for
    /// — symbol, title, subtitle — sized by the real row's own layout.
    @Test func aSkeletonRowLaysABoneOverEachPartOfTheRow() {
        let cell = SettingsSkeletonRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 64))
        var content = UIListContentConfiguration.subtitleCell()
        content.text = "iPhone"
        content.secondaryText = "iOS 27.0 · This device"
        content.image = UIImage(systemName: "iphone")
        cell.configure(redacting: content)
        cell.layoutIfNeeded()
        let bones = cell.contentView.subviews.compactMap { $0 as? SkeletonBoneView }.filter { !$0.isHidden }
        #expect(bones.count == 3)
        #expect(bones.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 })

        var titleOnly = UIListContentConfiguration.cell()
        titleOnly.text = "Delete Account"
        cell.configure(redacting: titleOnly)
        cell.layoutIfNeeded()
        #expect(cell.contentView.subviews.compactMap { $0 as? SkeletonBoneView }.filter { !$0.isHidden }.count == 1)
    }

    /// Coming back re-reads the sessions; when that read fails the list on
    /// screen stays (the screen says so with a toast) instead of being
    /// replaced by the retry row.
    @Test func aFailedRefreshKeepsTheListAndReportsIt() async {
        let stub = StubSessions()
        let model = SecuritySettingsViewModel(sessions: stub)
        await model.load()
        guard case .loaded(let before) = model.phase else { Issue.record("not loaded"); return }
        var refreshFailures = 0
        model.onRefreshFailed = { refreshFailures += 1 }

        await stub.setFailsList(true)
        await model.load()
        #expect(model.phase == .loaded(before))
        #expect(refreshFailures == 1)
    }

    @Test func logOutEverywhereCallsTheGlobalRevoke() async throws {
        let stub = StubSessions()
        try await SecuritySettingsViewModel(sessions: stub).revokeAll()
        #expect(await stub.revokedAll)
    }
}

private actor StubSessions: AccountSessionsManaging {
    private var failsList: Bool
    private let failsRevoke: Bool
    private(set) var revoked: [String] = []
    private(set) var revokedAll = false

    init(failsList: Bool = false, failsRevoke: Bool = false) {
        self.failsList = failsList
        self.failsRevoke = failsRevoke
    }

    func setFailsList(_ value: Bool) { failsList = value }

    func activeSessions() async throws -> [AccountSession] {
        if failsList { throw AccountSessionsError.transport(message: "down") }
        return [
            AccountSession(id: "me", device: SessionDevice(userAgent: "core-platform-ios/1.0 (iPhone; iOS 27.0)"), isCurrent: true, signedInAt: nil),
            AccountSession(id: "ipad", device: SessionDevice(userAgent: "core-platform-ios/1.0 (iPad; iOS 26.4)"), isCurrent: false, signedInAt: nil)
        ]
    }

    func revokeSession(id: String) async throws {
        if failsRevoke { throw AccountSessionsError.transport(message: "down") }
        revoked.append(id)
    }

    func revokeAllSessions() async throws { revokedAll = true }
}
