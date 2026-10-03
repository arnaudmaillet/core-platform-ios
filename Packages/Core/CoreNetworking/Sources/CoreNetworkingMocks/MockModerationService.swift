import Connect
import CoreContracts
import Foundation
import SwiftProtobuf

/// Fake of moderation.v1 — the RPCs a *user-facing* surface calls: `OpenCase`
/// (the profile's Report action) and `GetEnforcementState` (Settings →
/// Account Status). The rest of the service is a moderator console
/// (`listQueue`, `assignCase`, `decideCase`, `resolveAppeal`) with no client
/// in this app, so mocking it would be fiction with no reader.
///
/// This mock is how the report flow is verified at all: `moderation.v1` is not
/// routed through the dev gateway (see `dev/BACKEND_GAPS.md` §11), so against
/// the local fleet the call does not currently land.
public final class MockModerationService: @unchecked Sendable {
    /// Cases opened this session, newest last — inspectable from tests so a
    /// report assertion can check the subject and category that were filed,
    /// not merely that the call succeeded.
    public var openedCases: [Moderation_V1_CaseView] {
        lock.withLock { storage }
    }

    private let lock = NSLock()
    private var storage: [Moderation_V1_CaseView] = []
    private let seedsViewerRestriction: Bool

    /// `seedsViewerRestriction` gives the viewer's account one active,
    /// time-boxed restriction (comments limited for a week).
    public init(seedsViewerRestriction: Bool = false) {
        self.seedsViewerRestriction = seedsViewerRestriction
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/moderation.v1.ModerationService/GetEnforcementState") { [self] (request: Moderation_V1_GetEnforcementStateRequest) in
            var response = Moderation_V1_GetEnforcementStateResponse()
            if seedsViewerRestriction, request.actorID == MockAuthService.accountID {
                var enforcement = Moderation_V1_EnforcementView()
                enforcement.enforcementID = "enf-seed-1"
                enforcement.subject.entityType = .account
                enforcement.subject.entityID = MockAuthService.accountID
                enforcement.subject.actorID = MockAuthService.accountID
                enforcement.action = .restrictActor
                enforcement.status = .active
                enforcement.version = 1
                enforcement.appliedAt = .init(date: Date().addingTimeInterval(-2 * 86_400))
                enforcement.expiresAt = .init(date: Date().addingTimeInterval(5 * 86_400))
                response.actorRestricted = true
                response.activeEnforcements = [enforcement]
            }
            return .success(response)
        }
        bff.register(path: "/moderation.v1.ModerationService/OpenCase") { [self] (request: Moderation_V1_OpenCaseRequest) in
            var response = Moderation_V1_OpenCaseResponse()
            // Idempotent open, per the contract: a second report of the same
            // subject by the same actor returns the EXISTING case with
            // `created = false` rather than stacking duplicates in the queue.
            if let existing = existingCase(for: request.subject) {
                response.case = existing
                response.created = false
                return .success(response)
            }

            var view = Moderation_V1_CaseView()
            // Deterministic id from the case index — no randomness, so a test
            // asserting on the returned id stays stable between runs.
            view.caseID = "case-\(nextCaseIndex())"
            view.subject = request.subject
            view.category = request.category
            view.status = .open
            view.queue = "default"
            view.priority = "normal"
            append(view)

            response.case = view
            response.created = true
            return .success(response)
        }
    }

    private func existingCase(for subject: Moderation_V1_SubjectRef) -> Moderation_V1_CaseView? {
        lock.withLock {
            storage.first {
                $0.subject.entityType == subject.entityType
                    && $0.subject.entityID == subject.entityID
                    && $0.subject.actorID == subject.actorID
            }
        }
    }

    private func nextCaseIndex() -> Int {
        lock.withLock { storage.count }
    }

    private func append(_ view: Moderation_V1_CaseView) {
        lock.withLock { storage.append(view) }
    }
}
