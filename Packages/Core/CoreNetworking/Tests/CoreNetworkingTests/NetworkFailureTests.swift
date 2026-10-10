import Connect
import Foundation
import Testing
@testable import CoreNetworking

/// A feature error shaped like the repositories' own: a transport case that
/// carries the failure, and a non-network case that carries none.
private enum StubFeatureError: Error, NetworkFailureCarrying {
    case notAuthenticated
    case transport(message: String, failure: NetworkFailure?)

    var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
}

/// #794: a failed call keeps WHY it failed, in words a screen can act on.
struct NetworkFailureTests {
    // MARK: - Connect codes

    /// Connect-Swift keeps the URLSession error in `exception` for a real
    /// transport failure: that is what says offline.
    @Test func aLostConnectionReadsAsOffline() {
        let error = ConnectError(code: .unavailable, message: "x", exception: URLError(.notConnectedToInternet))
        #expect(NetworkFailure(error) == .offline)
    }

    /// No `URLError` behind it: a server answered `unavailable` (the BFF, a
    /// gateway's 503). The device is online; saying otherwise misleads.
    @Test func aServerSentUnavailableIsNotOffline() {
        #expect(NetworkFailure(ConnectError(code: .unavailable, message: "x")) == .server(code: "unavailable"))
        #expect(NetworkFailure(code: .unavailable) == .server(code: "unavailable"))
    }

    @Test func aDeadlineReadsAsATimeout() {
        #expect(NetworkFailure(code: .deadlineExceeded) == .timeout)
    }

    @Test(arguments: [
        (Code.permissionDenied, "permission_denied"),
        (.notFound, "not_found"),
        (.invalidArgument, "invalid_argument"),
        (.failedPrecondition, "failed_precondition"),
        (.unauthenticated, "unauthenticated")
    ])
    func aServerRefusalKeepsItsCode(code: Code, name: String) {
        #expect(NetworkFailure(code: code) == .refused(code: name))
    }

    @Test(arguments: [
        (Code.internalError, "internal"),
        (.unknown, "unknown"),
        (.resourceExhausted, "resource_exhausted")
    ])
    func aServerFaultKeepsItsCode(code: Code, name: String) {
        #expect(NetworkFailure(code: code) == .server(code: name))
    }

    @Test func aCancelledCallIsNotAFailureToRetry() {
        #expect(NetworkFailure(code: .canceled) == .cancelled)
        #expect(!NetworkFailure.cancelled.isRetryable)
    }

    // MARK: - URLErrors

    @Test(arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed])
    func aDeviceWithoutAConnectionReadsAsOffline(code: URLError.Code) {
        #expect(NetworkFailure(URLError(code)) == .offline)
    }

    @Test func aTimedOutRequestReadsAsATimeout() {
        #expect(NetworkFailure(URLError(.timedOut)) == .timeout)
    }

    /// The device is online; the other end is what failed.
    @Test func anUnreachableHostIsNotOffline() {
        let failure = NetworkFailure(URLError(.cannotConnectToHost))
        #expect(failure != .offline)
        #expect(failure.isRetryable)
    }

    /// Connect folds an unreachable host into `unavailable`; the `URLError` it
    /// keeps in `exception` is what tells the two apart.
    @Test func theURLErrorBehindAConnectErrorWins() {
        let unreachable = ConnectError(code: .unavailable, message: "x", exception: URLError(.cannotFindHost))
        let offline = ConnectError(code: .unavailable, message: "x", exception: URLError(.notConnectedToInternet))

        #expect(NetworkFailure(unreachable) != .offline)
        #expect(NetworkFailure(offline) == .offline)
    }

    // MARK: - Reading it off any error

    @Test func aCarryingErrorAnswersWithWhatItCarries() {
        #expect(NetworkFailure.of(StubFeatureError.transport(message: "x", failure: .timeout)) == .timeout)
        #expect(NetworkFailure.of(StubFeatureError.notAuthenticated) == nil)
    }

    @Test func aRawConnectOrURLErrorIsReadDirectly() {
        let offline = ConnectError(code: .unavailable, message: nil, exception: URLError(.networkConnectionLost))
        #expect(NetworkFailure.of(offline) == .offline)
        #expect(NetworkFailure.of(ConnectError(code: .unavailable, message: nil)) == .server(code: "unavailable"))
        #expect(NetworkFailure.of(URLError(.timedOut)) == .timeout)
    }

    @Test func anErrorFromElsewhereHasNoNetworkFailure() {
        #expect(NetworkFailure.of(CocoaError(.fileNoSuchFile)) == nil)
    }

    @Test func onlyARefusalOrACancelIsNotRetryable() {
        #expect(NetworkFailure.offline.isRetryable)
        #expect(NetworkFailure.timeout.isRetryable)
        #expect(NetworkFailure.server(code: "internal").isRetryable)
        #expect(!NetworkFailure.refused(code: "not_found").isRetryable)
    }

    // MARK: - Copy

    @Test func anOfflineFailureSaysYoureOffline() {
        let error = StubFeatureError.transport(message: "x", failure: .offline)
        #expect(FailureCopy.message(for: error, fallback: "Couldn't load.")
            == "You're offline. Check your connection and try again.")
    }

    @Test func aTimeoutSaysItIsTakingTooLong() {
        let error = StubFeatureError.transport(message: "x", failure: .timeout)
        #expect(FailureCopy.message(for: error, fallback: "Couldn't load.") == "This is taking too long. Try again.")
    }

    @Test(arguments: [NetworkFailure.server(code: "internal"), .refused(code: "not_found"), .cancelled])
    func anyOtherFailureKeepsTheScreensOwnWords(failure: NetworkFailure) {
        let error = StubFeatureError.transport(message: "x", failure: failure)
        #expect(FailureCopy.message(for: error, fallback: "Couldn't load.") == "Couldn't load.")
    }

    @Test func aNonNetworkErrorKeepsTheScreensOwnWords() {
        #expect(FailureCopy.message(for: StubFeatureError.notAuthenticated, fallback: "Couldn't load.")
            == "Couldn't load.")
    }
}
