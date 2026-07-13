import Foundation

/// Pure validation for the email sign-in screen.
///
/// The backend IdP authenticates BARE USERNAMES, not only emails (see
/// `dev/BACKEND_GAPS.md` §6 — the mock fixture is `demo`, the fleet account
/// `alice`), so a plain word is accepted alongside a well-formed address.
enum EmailAddress {
    /// The normalized login token, or nil while the input isn't submittable.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard let at = trimmed.firstIndex(of: "@") else { return trimmed } // bare username
        let local = trimmed[..<at]
        let domain = trimmed[trimmed.index(after: at)...]
        guard !local.isEmpty,
              !domain.isEmpty,
              !domain.contains("@"),
              domain.contains("."),
              !domain.hasPrefix("."),
              !domain.hasSuffix(".")
        else { return nil }
        return trimmed
    }
}

// Phone validation lives with `CountryDialCode`: the phone screen is
// country-aware, so free-form parsing has no remaining consumer.
