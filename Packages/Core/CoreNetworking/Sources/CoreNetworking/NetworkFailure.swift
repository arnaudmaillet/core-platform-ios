import Connect
import Foundation

/// WHY a network call failed, in the few words a screen needs to word it and to
/// decide whether a retry can help (#794).
///
/// ⚠️ Every feature repository used to fold a `ConnectError` into its own
/// `XError.transport(message:)` and drop the `Code` on the floor. Connect had
/// already told us the device was offline (`unavailable`) or the call ran out
/// of time (`deadlineExceeded`), and by the time the error reached a view model
/// all that was left was a server string nobody shows. So every failed screen
/// said the same vague thing, offline or not. This is the part worth keeping,
/// carried next to the message rather than lost.
///
/// Deliberately coarse: four outcomes a person can act on differently, not a
/// mirror of Connect's sixteen codes. The code itself survives as a string on
/// the two cases where the server answered, for logs and tests.
public enum NetworkFailure: Equatable, Sendable {
    /// The device has no usable connection: no internet, the link dropped
    /// mid-call, cellular data is off for the app. The person can fix it
    /// themselves; the copy should say so.
    ///
    /// ⚠️ Built ONLY from a `URLError` (`notConnectedToInternet` and friends),
    /// never from Connect's `unavailable` code alone. Connect-Swift attaches
    /// the URLSession error to `ConnectError.exception` for every real
    /// transport failure; an `unavailable` WITHOUT one means a server did
    /// answer — the BFF's own `unavailable`, an HTTP 429/502/503/504, a
    /// gateway's HTML 503 — and telling the person "you're offline" then
    /// sends them to fix a connection that works. Those read as `.server`.
    case offline
    /// The call ran out of time (`deadlineExceeded`, `URLError.timedOut`). The
    /// network may be slow rather than gone; worth another try.
    case timeout
    /// The server answered and said no: a refusal the same request will keep
    /// getting (`permission_denied`, `not_found`, `invalid_argument`...).
    /// Retrying it as-is is pointless; the screen should explain instead.
    case refused(code: String)
    /// The server, or something on the way to it, broke (`internal`,
    /// `unknown`, `resource_exhausted`, a host we cannot reach...). Not the
    /// person's doing, and often transient.
    case server(code: String)
    /// The caller gave up (`canceled`, `URLError.cancelled`): a superseded
    /// query, a screen that went away. Not a failure anyone should be shown.
    case cancelled
}

public extension NetworkFailure {
    /// Whether the SAME request has a fair chance of succeeding later. A
    /// refusal does not, and a cancelled call was abandoned on purpose.
    var isRetryable: Bool {
        switch self {
        case .offline, .timeout, .server: true
        case .refused, .cancelled: false
        }
    }

    /// Classifies a Connect failure. The `URLError` Connect wraps in
    /// `exception` decides when there is one: it is the only evidence the
    /// device itself is offline (Connect folds a dropped link, an unreachable
    /// host and a server's 503 into one `unavailable`). Without one, a server
    /// answered, and the code says how.
    init(_ error: ConnectError) {
        if let urlError = error.exception as? URLError {
            self.init(urlError)
        } else {
            self.init(code: error.code)
        }
    }

    /// Classifies a `URLError` thrown before Connect ever saw a response (or
    /// by a plain `URLSession` call such as a media upload).
    init(_ error: URLError) {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
            self = .offline
        case .timedOut:
            self = .timeout
        case .cancelled:
            self = .cancelled
        default:
            // A host we cannot find or reach, a TLS failure, a bad response:
            // the device is online, the other end is the problem.
            self = .server(code: "urlerror_\(error.code.rawValue)")
        }
    }
}

extension NetworkFailure {
    /// Classifies a code a SERVER answered with (no `URLError` behind it).
    ///
    /// ⚠️ Internal on purpose: a bare code cannot tell offline from a server
    /// outage, so it never yields `.offline` — `unavailable` reads as
    /// `.server`. Screens go through `init(_: ConnectError)` or
    /// `NetworkFailure.of(_:)`, which see the `URLError` when there is one.
    init(code: Code) {
        switch code {
        case .unavailable:
            self = .server(code: code.name)
        case .deadlineExceeded:
            self = .timeout
        case .canceled:
            self = .cancelled
        case .invalidArgument, .notFound, .alreadyExists, .permissionDenied,
             .failedPrecondition, .outOfRange, .unimplemented, .unauthenticated:
            self = .refused(code: code.name)
        case .ok, .unknown, .resourceExhausted, .aborted, .internalError, .dataLoss:
            self = .server(code: code.name)
        }
    }
}

public extension NetworkFailure {
    /// The failure behind any error a repository may throw, or nil when it did
    /// not come from the network (a missing session, a domain refusal the
    /// feature already names).
    ///
    /// Reads, in order: a feature error that carries one
    /// (`NetworkFailureCarrying`), a raw `ConnectError`, a raw `URLError`.
    static func of(_ error: any Error) -> NetworkFailure? {
        if let carrying = error as? any NetworkFailureCarrying {
            return carrying.networkFailure
        }
        if let connect = error as? ConnectError {
            return NetworkFailure(connect)
        }
        if let url = error as? URLError {
            return NetworkFailure(url)
        }
        return nil
    }
}

/// A feature error that remembers why the network call behind it failed
/// (#794).
///
/// Conformed by each repository's error enum instead of replacing its cases,
/// so the dozens of `switch`es over `FeedError`, `ChatError`... keep compiling
/// and keep meaning what they meant; only the screens that want to word a
/// failure better ask `NetworkFailure.of(error)`.
public protocol NetworkFailureCarrying: Error {
    /// Nil when this error did not come from the network.
    var networkFailure: NetworkFailure? { get }
}

/// The words a failed screen shows, picked from WHY it failed (#794).
///
/// ⚠️ Only "offline" and a timeout get their own sentence. Offline is the one
/// case a person can fix themselves, and the one every screen was getting
/// wrong by saying "Couldn't load" as if the app or the server were at fault;
/// a timeout is worth another try rather than a verdict. Server faults and
/// refusals keep each screen's own fallback, which already names what failed
/// ("Couldn't search for people").
public enum FailureCopy {
    /// What to say when the device has no connection. Shared so every screen
    /// says it the same way.
    ///
    /// The curly apostrophe (U+2019), as everywhere else the app writes one.
    public static let offline = "You\u{2019}re offline. Check your connection and try again."
    /// What to say when the call ran out of time: the network may be slow
    /// rather than gone. For a screen with a Try Again under it.
    public static let timeout = "That took too long. Try again."

    /// The short forms, for a headline or a toast (`Feedback`: short, no
    /// trailing period, no "Try again" when the screen retries by itself).
    public static let offlineTitle = "You\u{2019}re offline"
    public static let timeoutTitle = "That took too long"

    /// The offline or timeout sentence when that is why `error` happened,
    /// else `fallback` (the screen's own wording).
    public static func message(for error: any Error, fallback: String) -> String {
        switch NetworkFailure.of(error) {
        case .offline: offline
        case .timeout: timeout
        default: fallback
        }
    }

    /// The short form of `message(for:fallback:)`: `offlineTitle`,
    /// `timeoutTitle`, else `fallback`. For toasts and headlines.
    public static func title(for error: any Error, fallback: String) -> String {
        switch NetworkFailure.of(error) {
        case .offline: offlineTitle
        case .timeout: timeoutTitle
        default: fallback
        }
    }
}
