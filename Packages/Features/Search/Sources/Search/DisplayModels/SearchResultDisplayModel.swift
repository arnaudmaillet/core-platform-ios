import CoreModels
import Foundation

/// View-ready projection of a `ProfileSearchResult`: pre-formatted so the cell
/// does no logic.
public struct SearchResultDisplayModel: Equatable, Sendable, Identifiable {
    public let id: ProfileID
    public let displayName: String
    /// "@handle" with the sigil applied once, here.
    public let handle: String
    public let isVerified: Bool
    /// One- or two-letter avatar fallback (search hits carry no avatar URL,
    /// only a storage key, so the monogram is always what renders today).
    public let monogram: String

    public init(result: ProfileSearchResult) {
        id = result.id
        displayName = result.displayName
        handle = "@" + result.handle
        isVerified = result.isVerified
        monogram = Self.monogram(displayName: result.displayName, handle: result.handle)
    }

    static func monogram(displayName: String, handle: String) -> String {
        let source = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? handle : displayName
        let initials = source
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
        return initials.isEmpty ? "?" : initials.joined()
    }
}
