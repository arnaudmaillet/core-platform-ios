import CryptoKit
import Foundation

/// The id_tokens the mock's Sign in with Apple / Google takes: an unsigned
/// JWT (`alg: none`) with the claims the fleet reads. A DEBUG provider and
/// the tests mint them; the mock decodes them without a signature check.
public enum MockIdToken {
    public struct Claims: Equatable, Sendable {
        public let subject: String
        public let email: String?
        public let nonce: String
    }

    /// A token for `subject`, minted for `nonce` as Apple does (its SHA-256
    /// hex) unless `hashNonce` is false (Google's raw nonce).
    public static func make(subject: String, email: String?, nonce: String, hashNonce: Bool = true) -> String {
        var payload: [String: String] = [
            "iss": "https://appleid.apple.com",
            "sub": subject,
            "nonce": hashNonce ? sha256Hex(nonce) : nonce,
        ]
        payload["email"] = email
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)) ?? Data()
        return "\(base64URL(header)).\(base64URL(body))."
    }

    public static func claims(of token: String) -> Claims? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let data = data(base64URL: String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String,
              let nonce = object["nonce"] as? String
        else { return nil }
        return Claims(subject: subject, email: object["email"] as? String, nonce: nonce)
    }

    public static func sha256Hex(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(base64URL: String) -> Data? {
        var base64 = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
