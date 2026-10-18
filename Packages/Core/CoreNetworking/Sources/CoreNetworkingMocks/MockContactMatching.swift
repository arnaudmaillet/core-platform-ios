import Connect
import CoreContracts
import CryptoKit
import Foundation
import SwiftProtobuf

/// Fake of `account.v1.AccountService/FindProfilesByContacts` (#412, backend
/// #806), with the fleet's rules:
/// - hashes are SHA-256 of a lower-cased, trimmed email or an E.164 number;
///   at most 1000 per call, each 32 bytes, else ACC-9001 (INVALID_ARGUMENT);
/// - a contact matches an ACTIVE account's VERIFIED email or phone, then its
///   profiles findable through that channel (`by_email` / `by_phone`);
/// - never the caller's own account, never a profile one of the caller's
///   profiles blocks or is blocked by;
/// - every submitted hash counts against a daily budget per account
///   (5000, ACC-7007 RESOURCE_EXHAUSTED past it).
///
/// The directory is seeded against the iOS SIMULATOR's sample contacts, so
/// the screen finds people in mock mode: Kate Bell, Daniel Higgins and John
/// Appleseed match by email, David Taylor by phone (in a NANP region —
/// elsewhere his number reads as national and is skipped). Anna Haro's email
/// is unverified and Hank Zakroff's account is deactivated: neither matches.
public final class MockContactMatching: @unchecked Sendable {
    /// One account's contact details, as `account` holds them.
    public struct Entry: Sendable {
        public let accountID: String
        public let email: String
        public let emailVerified: Bool
        /// E.164, empty for none.
        public let phone: String
        public let phoneVerified: Bool
        public let isActive: Bool
    }

    public static let maxHashesPerCall = 1_000
    public static let dailyLookups = 5_000

    public static let seededDirectory: [Entry] = [
        Entry(accountID: "acct-mock-prof-30", email: "kate-bell@mac.com", emailVerified: true, phone: "+14155553695", phoneVerified: true, isActive: true),
        Entry(accountID: "acct-mock-prof-31", email: "d-higgins@mac.com", emailVerified: true, phone: "+15554787672", phoneVerified: false, isActive: true),
        Entry(accountID: "acct-mock-prof-32", email: "John-Appleseed@mac.com", emailVerified: true, phone: "", phoneVerified: false, isActive: true),
        Entry(accountID: "acct-mock-prof-33", email: "anna-haro@mac.com", emailVerified: false, phone: "", phoneVerified: false, isActive: true),
        Entry(accountID: "acct-mock-prof-34", email: "hank-zakroff@mac.com", emailVerified: true, phone: "+15557664823", phoneVerified: true, isActive: false),
        Entry(accountID: "acct-mock-prof-35", email: "", emailVerified: false, phone: "+15556106679", phoneVerified: true, isActive: true),
    ]

    private let dataset: MockSocialDataset
    private let lifecycle: MockAccountLifecycle
    private let directory: [Entry]
    private let isFindable: @Sendable (_ profileID: String, _ byPhone: Bool) -> Bool
    private let isHidden: @Sendable (_ viewer: String, _ target: String) -> Bool
    private let lock = NSLock()
    private var lookups: (day: String, count: Int) = ("", 0)

    /// - Parameters:
    ///   - lifecycle: holds the caller's own email and phone, matched like
    ///     anyone's so the "never your own" rule has something to drop.
    ///   - isFindable: the profile's `by_phone` (true) or `by_email` switch.
    ///   - isHidden: a block either way between two profiles.
    public init(
        dataset: MockSocialDataset,
        lifecycle: MockAccountLifecycle,
        directory: [Entry] = MockContactMatching.seededDirectory,
        isFindable: @escaping @Sendable (String, Bool) -> Bool,
        isHidden: @escaping @Sendable (String, String) -> Bool
    ) {
        self.dataset = dataset
        self.lifecycle = lifecycle
        self.directory = directory
        self.isFindable = isFindable
        self.isHidden = isHidden
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/account.v1.AccountService/FindProfilesByContacts") { [self] (request: Account_V1_FindProfilesByContactsRequest) in
            find(request)
        }
    }

    static func sha256(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }

    private func find(_ request: Account_V1_FindProfilesByContactsRequest) -> Result<Account_V1_FindProfilesByContactsResponse, ConnectError> {
        guard request.accountID == MockAuthService.accountID else {
            return .failure(ConnectError(code: .permissionDenied, message: "not the caller's account"))
        }
        let submitted = request.emailSha256.count + request.phoneSha256.count
        guard submitted <= Self.maxHashesPerCall else {
            return .failure(ConnectError(code: .invalidArgument, message: "ACC-9001: at most 1000 hashes per call"))
        }
        guard (request.emailSha256 + request.phoneSha256).allSatisfy({ $0.count == 32 }) else {
            return .failure(ConnectError(code: .invalidArgument, message: "ACC-9001: each hash is a 32-byte SHA-256"))
        }
        guard submitted > 0 else { return .success(Account_V1_FindProfilesByContactsResponse()) }
        guard reserve(submitted) else {
            return .failure(ConnectError(code: .resourceExhausted, message: "ACC-7007: daily contact lookups used up"))
        }

        let own = lifecycle.contact
        let entries = directory + [Entry(
            accountID: MockAuthService.accountID, email: own.email, emailVerified: own.emailVerified,
            phone: own.phone.filter { $0 == "+" || $0.isNumber }, phoneVerified: own.phoneVerified, isActive: true
        )]
        let emails = Set(request.emailSha256)
        let phones = Set(request.phoneSha256)
        let viewers = dataset.profileIDs(inAccount: MockAuthService.accountID)
        var response = Account_V1_FindProfilesByContactsResponse()
        var seen: Set<String> = []
        for entry in entries where entry.isActive && entry.accountID != MockAuthService.accountID {
            var channels: [(Data, Account_V1_ContactChannel, Bool)] = []
            if entry.emailVerified, !entry.email.isEmpty {
                let hash = Self.sha256(entry.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                if emails.contains(hash) { channels.append((hash, .email, false)) }
            }
            if entry.phoneVerified, !entry.phone.isEmpty {
                let hash = Self.sha256(entry.phone)
                if phones.contains(hash) { channels.append((hash, .phone, true)) }
            }
            for (hash, channel, byPhone) in channels {
                for profileID in dataset.profileIDs(inAccount: entry.accountID) where isFindable(profileID, byPhone) {
                    guard !viewers.contains(where: { isHidden($0, profileID) }),
                          seen.insert("\(profileID)|\(hash.base64EncodedString())").inserted,
                          let author = dataset.author(for: profileID) else { continue }
                    var profile = Account_V1_ContactProfile()
                    profile.contactSha256 = hash
                    profile.channel = channel
                    profile.profileID = profileID
                    profile.handle = author.handle
                    profile.displayName = author.displayName
                    profile.avatarURL = author.avatarURL
                    response.profiles.append(profile)
                }
            }
        }
        return .success(response)
    }

    /// Every submitted hash counts, matched or not, before anything is
    /// matched — the fleet's budget per account and UTC day.
    private func reserve(_ count: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        let day = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        return lock.withLock {
            if lookups.day != day { lookups = (day, 0) }
            guard lookups.count + count <= Self.dailyLookups else { return false }
            lookups.count += count
            return true
        }
    }
}
