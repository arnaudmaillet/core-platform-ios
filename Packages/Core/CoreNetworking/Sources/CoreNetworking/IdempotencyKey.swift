import Connect
import CryptoKit
import Foundation

/// The client key a chat.v1 `SendMessage` and a post.v1 `CreatePost` carry
/// (#795): one per message or post, minted once and reused on every retry.
///
/// Both contracts take 8–64 characters of letters, digits, `-` and `_`
/// (CHT-2010 / PST-9006 otherwise). A repeat within 24 hours stores nothing
/// and answers what the first call stored; while that first call is still in
/// flight a repeat fails ABORTED (CHT-1013 / PST-1010), which means "retry
/// later", not "this failed".
public enum IdempotencyKey {
    /// A fresh key: a UUID, 36 characters of hex digits and dashes.
    public static func mint() -> String { UUID().uuidString }

    /// Whether `key` is one the contracts accept as it stands.
    public static func isValid(_ key: String) -> Bool {
        (8...64).contains(key.count) && key.unicodeScalars.allSatisfy(isAllowed)
    }

    /// `key` as it goes on the wire: unchanged when the contracts accept it,
    /// otherwise a stable digest of it (32 hex characters) — so a caller's
    /// own identity, whatever its shape, still names one send and one only.
    /// Empty stays empty: no deduplication.
    public static func wire(_ key: String) -> String {
        guard !key.isEmpty, !isValid(key) else { return key }
        let digest = SHA256.hash(data: Data(key.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// How long a keyed write waits before asking again while its first
    /// attempt is still in flight on the server (ABORTED). After the last,
    /// the write fails like any other and the screen offers its own retry,
    /// which goes under the same key.
    public static let inFlightRetryDelays: [Duration] = [.milliseconds(300), .seconds(1), .seconds(2)]

    /// Whether `error` is the contract's "the first call with this key is
    /// still in flight" — ABORTED with that write's own code (`CHT-1013`,
    /// `PST-1010`), the only ABORTED a keyed write waits out and repeats.
    ///
    /// ⚠️ The services answer it as ABORTED with their error's TEXT ("… with
    /// this idempotency key is in flight …"), the code staying in their logs
    /// (backend `status_from_app` / `app_err_to_status`), so either one marks
    /// it. Any other ABORTED is a failure like the rest.
    public static func isInFlight(_ error: ConnectError?, code: String) -> Bool {
        guard let error, error.code == .aborted else { return false }
        let message = error.message ?? ""
        return message.contains(code) || message.contains("idempotency key is in flight")
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "-", "_": true
        default: false
        }
    }
}
