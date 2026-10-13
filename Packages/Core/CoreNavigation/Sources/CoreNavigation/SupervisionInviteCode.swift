import Foundation

/// A family supervision invite code (#417, backend #670): 10 characters of
/// Crockford base32, single use, valid 24 hours. The server reads it ignoring
/// case, spaces and dashes; this does the same, so a code typed from a
/// screen, pasted from a message or read from a link all mean one thing.
public enum SupervisionInviteCode {
    /// The code's length once spaces and dashes are gone.
    public static let length = 10

    /// The code uppercased, without spaces or dashes; nil unless that leaves
    /// exactly `length` ASCII letters and digits. The alphabet itself is the
    /// server's to check (it also reads Crockford's look-alikes).
    public static func normalized(_ raw: String) -> String? {
        let code = raw.uppercased().filter { $0 != " " && $0 != "-" }
        guard code.count == length, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return code
    }

    /// "K7M2Q-9XRTD": two halves, easier to read out and to type.
    public static func display(_ code: String) -> String {
        guard code.count == length else { return code }
        let middle = code.index(code.startIndex, offsetBy: length / 2)
        return "\(code[..<middle])-\(code[middle...])"
    }

    /// The link a QR code and the share sheet carry:
    /// `https://core-platform.click/family/<code>`.
    ///
    /// ⚠️ The universal link needs `/family/*` in the site association
    /// (core-platform-infra `app-site-association`), which lists only `/@*`,
    /// `/tag/*` and `/s/*` today; until then the link opens the web, and the
    /// code typed by hand or `wynn:/family/<code>` opens the app.
    public static func link(for code: String) -> URL? {
        URL(string: "https://\(AppRoute.webHost)/family/\(code)")
    }
}
