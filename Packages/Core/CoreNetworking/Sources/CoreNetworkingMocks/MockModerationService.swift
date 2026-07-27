import Connect
import CoreContracts
import Foundation

/// Fake of moderation.v1 — currently just the one RPC a *user-facing* surface
/// calls, `OpenCase` (the profile's Report action). The rest of the service is
/// a moderator console (`listQueue`, `assignCase`, `decideCase`, appeals) with
/// no client in this app, so mocking it would be fiction with no reader.
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

    public init() {}

    public func register(on bff: MockBFF) {
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
