import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CryptoKit
import Foundation

/// How a contact led to a profile: its email address or its phone number.
public enum ContactChannel: Equatable, Sendable {
    case email
    case phone
}

/// A profile found through one of the viewer's contacts (#412,
/// `AccountService/FindProfilesByContacts`, backend #806).
public struct ContactProfileMatch: Equatable, Sendable {
    /// The hash the app sent, so the screen can name the contact.
    public let contactHash: Data
    public let channel: ContactChannel
    public let profileID: ProfileID
    public let handle: String
    public let displayName: String
    public let avatarURL: URL?

    public init(
        contactHash: Data, channel: ContactChannel, profileID: ProfileID,
        handle: String, displayName: String, avatarURL: URL?
    ) {
        self.contactHash = contactHash
        self.channel = channel
        self.profileID = profileID
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

public enum ContactMatchError: Error, Equatable, Sendable {
    /// The account looked up its daily share of contacts (ACC-7007,
    /// RESOURCE_EXHAUSTED): the same call is refused until tomorrow (UTC).
    case dailyLimitReached
}

/// Finds the profiles behind contacts' hashed identifiers. One call takes at
/// most `maxHashesPerCall` hashes, emails and phones together; the server
/// keeps none of them.
public protocol ContactProfileFinding: Sendable {
    func findProfiles(emailHashes: [Data], phoneHashes: [Data]) async throws -> [ContactProfileMatch]
}

public enum ContactLookupLimits {
    /// The contract's cap per call, emails and phones together (ACC-9001
    /// past it).
    public static let maxHashesPerCall = 1_000
}

extension AccountRepository: ContactProfileFinding {
    public func findProfiles(emailHashes: [Data], phoneHashes: [Data]) async throws -> [ContactProfileMatch] {
        guard !emailHashes.isEmpty || !phoneHashes.isEmpty else { return [] }
        var request = Account_V1_FindProfilesByContactsRequest()
        request.accountID = try await accountID()
        request.emailSha256 = emailHashes
        request.phoneSha256 = phoneHashes
        let response = await accountClient.findProfilesByContacts(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return body.profiles.map { profile in
                ContactProfileMatch(
                    contactHash: profile.contactSha256,
                    channel: profile.channel == .phone ? .phone : .email,
                    profileID: ProfileID(profile.profileID),
                    handle: profile.handle,
                    displayName: profile.displayName,
                    avatarURL: profile.avatarURL.isEmpty ? nil : URL(string: profile.avatarURL)
                )
            }
        case .failure(let error):
            if error.code == .resourceExhausted { throw ContactMatchError.dailyLimitReached }
            throw Self.accountError(error)
        }
    }
}

/// The contract's normalization (backend #806, migration 0007), and the
/// SHA-256 the server compares: an email address lower-cased and trimmed, a
/// phone number in E.164 ("+33612345678"), each hashed as UTF-8.
///
/// ⚠️ A number written without its country code is read in the DEVICE's
/// region. Where the region is unknown, or the digits don't fit its national
/// numbers, the number is skipped: a guessed country code would only ever
/// hash someone else's number.
public enum ContactIdentifiers {
    /// A region's dialing plan, as far as reading a national number needs.
    public struct DialingPlan: Equatable, Sendable {
        /// Country calling code, digits only ("33").
        public let callingCode: String
        /// The national trunk prefix dropped before the calling code ("0"),
        /// nil where numbers keep their leading digit (Italy).
        public let trunkPrefix: String?
        /// The prefix dialed before an international number, besides "00"
        /// and "+" ("011" in the NANP).
        public let internationalPrefix: String
        /// National significant number lengths, after the trunk prefix.
        public let nationalLengths: ClosedRange<Int>

        public init(callingCode: String, trunkPrefix: String?, internationalPrefix: String = "00", nationalLengths: ClosedRange<Int>) {
            self.callingCode = callingCode
            self.trunkPrefix = trunkPrefix
            self.internationalPrefix = internationalPrefix
            self.nationalLengths = nationalLengths
        }
    }

    /// The regions whose national numbers the app can read. A region not
    /// listed still matches every number written with its country code.
    public static let plans: [String: DialingPlan] = {
        let nanp = DialingPlan(callingCode: "1", trunkPrefix: "1", internationalPrefix: "011", nationalLengths: 10...10)
        return [
            "US": nanp, "CA": nanp,
            "FR": DialingPlan(callingCode: "33", trunkPrefix: "0", nationalLengths: 9...9),
            "BE": DialingPlan(callingCode: "32", trunkPrefix: "0", nationalLengths: 8...9),
            "CH": DialingPlan(callingCode: "41", trunkPrefix: "0", nationalLengths: 9...9),
            "LU": DialingPlan(callingCode: "352", trunkPrefix: nil, nationalLengths: 6...11),
            "MC": DialingPlan(callingCode: "377", trunkPrefix: nil, nationalLengths: 8...9),
            "GB": DialingPlan(callingCode: "44", trunkPrefix: "0", nationalLengths: 9...10),
            "IE": DialingPlan(callingCode: "353", trunkPrefix: "0", nationalLengths: 7...9),
            "DE": DialingPlan(callingCode: "49", trunkPrefix: "0", nationalLengths: 6...11),
            "AT": DialingPlan(callingCode: "43", trunkPrefix: "0", nationalLengths: 6...12),
            "NL": DialingPlan(callingCode: "31", trunkPrefix: "0", nationalLengths: 9...9),
            "ES": DialingPlan(callingCode: "34", trunkPrefix: nil, nationalLengths: 9...9),
            "PT": DialingPlan(callingCode: "351", trunkPrefix: nil, nationalLengths: 9...9),
            "IT": DialingPlan(callingCode: "39", trunkPrefix: nil, nationalLengths: 6...11),
            "CN": DialingPlan(callingCode: "86", trunkPrefix: "0", nationalLengths: 9...11),
            "HK": DialingPlan(callingCode: "852", trunkPrefix: nil, nationalLengths: 8...8),
            "TW": DialingPlan(callingCode: "886", trunkPrefix: "0", nationalLengths: 8...9),
            "JP": DialingPlan(callingCode: "81", trunkPrefix: "0", internationalPrefix: "010", nationalLengths: 9...10),
            "KR": DialingPlan(callingCode: "82", trunkPrefix: "0", nationalLengths: 8...10),
            "SG": DialingPlan(callingCode: "65", trunkPrefix: nil, nationalLengths: 8...8),
            "AU": DialingPlan(callingCode: "61", trunkPrefix: "0", internationalPrefix: "0011", nationalLengths: 9...9),
            "IN": DialingPlan(callingCode: "91", trunkPrefix: "0", nationalLengths: 10...10),
            "BR": DialingPlan(callingCode: "55", trunkPrefix: "0", nationalLengths: 10...11),
            "MA": DialingPlan(callingCode: "212", trunkPrefix: "0", nationalLengths: 9...9),
        ]
    }()

    /// Lower-cased and trimmed, as the server hashes its own; nil for
    /// something that is no address.
    public static func normalizedEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = email.firstIndex(of: "@"), at != email.startIndex, email.index(after: at) != email.endIndex,
              !email.contains(where: \.isWhitespace) else { return nil }
        return email
    }

    /// E.164 ("+33612345678"), reading a national number in `region`'s plan;
    /// nil when the number can't be read with certainty.
    public static func normalizedPhone(_ raw: String, region: String?) -> String? {
        // "+33 (0)6 12…": the bracketed trunk zero is dialed only at home.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "(0)", with: "")
        // Letters (vanity numbers, "ext") and anything after them: the
        // number ends where they start.
        let numberPart = trimmed.prefix { !$0.isLetter && $0 != ";" && $0 != "," }
        let digits = numberPart.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let plan = region.flatMap { plans[$0.uppercased()] }

        var international: Substring?
        if numberPart.first(where: { !$0.isWhitespace }) == "+" {
            international = Substring(digits)
        } else if digits.hasPrefix("00") {
            international = digits.dropFirst(2)
        } else if let plan, plan.internationalPrefix != "00", digits.hasPrefix(plan.internationalPrefix) {
            international = digits.dropFirst(plan.internationalPrefix.count)
        }
        if let international {
            // E.164: at most 15 digits; shorter than 8 is no subscriber.
            guard (8...15).contains(international.count), international.first != "0" else { return nil }
            return "+" + international
        }

        guard let plan else { return nil }
        var national = Substring(digits)
        if let trunk = plan.trunkPrefix, national.hasPrefix(trunk),
           plan.nationalLengths.contains(national.count - trunk.count) {
            national = national.dropFirst(trunk.count)
        } else if plan.trunkPrefix == "0", national.hasPrefix("0") {
            return nil
        }
        guard plan.nationalLengths.contains(national.count) else { return nil }
        let e164: String = "+\(plan.callingCode)\(national)"
        return e164.count - 1 <= 15 ? e164 : nil
    }

    /// SHA-256 of the normalized identifier's UTF-8 bytes (32 bytes).
    public static func hash(_ normalized: String) -> Data {
        Data(SHA256.hash(data: Data(normalized.utf8)))
    }
}
