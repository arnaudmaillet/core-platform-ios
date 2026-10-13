@preconcurrency import Contacts
import Foundation

/// What the app may read of the address book.
public enum ContactBookAccess: Equatable, Sendable {
    /// Never asked: the screen explains first, then iOS asks.
    case notDetermined
    /// Refused, or not the person's to give (Screen Time, a managed device).
    case denied
    /// Only the contacts the person picked (iOS 18).
    case limited
    case authorized
}

/// One contact, as far as finding them goes: a name to show and the raw
/// identifiers to normalize. Nothing else is read.
public struct ContactEntry: Equatable, Sendable {
    public let name: String
    public let emails: [String]
    public let phones: [String]

    public init(name: String, emails: [String], phones: [String]) {
        self.name = name
        self.emails = emails
        self.phones = phones
    }
}

/// The address book, behind a seam the tests replace.
public protocol ContactBookReading: Sendable {
    func access() -> ContactBookAccess
    /// Shows the system prompt when never asked; answers the access after it.
    func requestAccess() async -> ContactBookAccess
    /// Every contact the app may read: all of them, or the picked ones.
    func entries() async throws -> [ContactEntry]
}

/// The device's address book (`CNContactStore`).
public struct SystemContactBook: ContactBookReading {
    public init() {}

    public func access() -> ContactBookAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: .notDetermined
        case .limited: .limited
        case .authorized: .authorized
        default: .denied
        }
    }

    public func requestAccess() async -> ContactBookAccess {
        guard access() == .notDetermined else { return access() }
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        return access()
    }

    /// Read off the caller's executor: enumerating a large book blocks.
    public func entries() async throws -> [ContactEntry] {
        try await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
            ]
            var entries: [ContactEntry] = []
            try CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                let emails = contact.emailAddresses.map { $0.value as String }
                let phones = contact.phoneNumbers.map { $0.value.stringValue }
                guard !emails.isEmpty || !phones.isEmpty else { return }
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                entries.append(ContactEntry(name: name, emails: emails, phones: phones))
            }
            return entries
        }.value
    }
}
