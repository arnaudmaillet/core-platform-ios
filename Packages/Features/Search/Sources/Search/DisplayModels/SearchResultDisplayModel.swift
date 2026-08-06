import CoreModels
import DesignSystem
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
    /// The person's picture, resolved after the hit arrives.
    ///
    /// ⚠️ Never comes from the search response. `Search_V1_ProfileHit` carries
    /// `avatar_key`, a storage key nothing in the app resolves — so this is
    /// filled in by `ProfileAvatarProviding` or not at all.
    public var avatarURL: URL?
    /// Social context, resolved after the hit arrives — `search.v1` says
    /// nothing about the viewer's relationship to a hit.
    public var context: ProfileRowContext = .none

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

extension SearchResultDisplayModel {
    /// This model as the shared row cell renders it.
    ///
    /// ⚠️ **The sigil is dropped here**, so a search result reads exactly like
    /// the same person in the compose picker and the inbox's search. It was
    /// kept while this screen drew its own row, and the two surfaces disagreed
    /// about whether a handle wears an "@" — which was only ever visible to
    /// someone who looked at both. `handle` itself keeps the sigil: it is what
    /// the model has always meant by that name, and the routing stub already
    /// strips it on the way out.
    var rowContent: PersonRowContent {
        PersonRowContent(
            displayName: displayName,
            handle: handle.hasPrefix("@") ? String(handle.dropFirst()) : handle,
            monogram: monogram,
            isVerified: isVerified,
            context: context
        )
    }
}
