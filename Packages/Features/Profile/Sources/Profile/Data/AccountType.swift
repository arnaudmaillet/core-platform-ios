import CoreContracts
import CoreModels
import Foundation

/// What kind of profile this is (#415, backend #734), public on every
/// profile view. A bot is set by the platform and can't be chosen.
public enum AccountType: Equatable, Sendable {
    case personal, creator, business, bot

    /// The choices an owner has; a bot has none.
    public static let choices: [AccountType] = [.personal, .creator, .business]

    public var title: String {
        switch self {
        case .personal: "Personal"
        case .creator: "Creator"
        case .business: "Business"
        case .bot: "Bot"
        }
    }

    public var detail: String {
        switch self {
        case .personal: "For sharing with friends and the people you follow."
        case .creator: "For public figures, artists and anyone building an audience. Your profile shows “Creator”."
        case .business: "For brands and shops. Your profile shows your category, and a contact card everyone can see."
        case .bot: "This profile is run by software."
        }
    }

    init(_ proto: Profile_V1_ProfileKind) {
        switch proto {
        case .professional: self = .creator
        case .brand: self = .business
        case .bot: self = .bot
        case .personal, .unspecified, .UNRECOGNIZED: self = .personal
        }
    }

    var proto: Profile_V1_ProfileKind {
        switch self {
        case .personal: .personal
        case .creator: .professional
        case .business: .brand
        case .bot: .bot
        }
    }
}

/// A business profile's public contact card.
public struct BusinessContact: Equatable, Sendable {
    public static let maximumCategoryLength = 64

    /// "Bakery", "Musician" — shown on the profile.
    public var category: String
    public var email: String
    public var phone: String

    public init(category: String, email: String = "", phone: String = "") {
        self.category = category
        self.email = email
        self.phone = phone
    }

    public var isValid: Bool {
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return !category.isEmpty && category.count <= Self.maximumCategoryLength
    }

    init(_ proto: Profile_V1_BusinessInfo) {
        self.init(category: proto.category, email: proto.contactEmail, phone: proto.contactPhone)
    }

    var proto: Profile_V1_BusinessInfo {
        var proto = Profile_V1_BusinessInfo()
        proto.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        proto.contactEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        proto.contactPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        return proto
    }
}

public enum AccountTypeError: Error, Equatable {
    /// The server refused the contact card (category, email or phone).
    case invalidContact(message: String)
    case transport(message: String)
}

/// Edit Profile → Account Type, for the active profile.
public protocol AccountTypeManaging: Sendable {
    func accountType() async throws -> (type: AccountType, contact: BusinessContact?)
    /// `contact` is required for a business and ignored otherwise.
    func setAccountType(_ type: AccountType, contact: BusinessContact?) async throws
}

extension ProfileRepository: AccountTypeManaging {
    public func accountType() async throws -> (type: AccountType, contact: BusinessContact?) {
        let view = try await fetchProfileView(id: try await resolveViewerProfileID())
        let type = AccountType(view.profileKind)
        return (type, type == .business && view.hasBusinessInfo ? BusinessContact(view.businessInfo) : nil)
    }

    public func setAccountType(_ type: AccountType, contact: BusinessContact?) async throws {
        var request = Profile_V1_SetAccountTypeRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "setAccountType").rawValue
        request.kind = type.proto
        if type == .business, let contact { request.business = contact.proto }
        let response = await profileClient.setAccountType(request: request, headers: [:])
        if let error = response.error {
            if error.code == .invalidArgument {
                throw AccountTypeError.invalidContact(message: error.message ?? "")
            }
            throw AccountTypeError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
