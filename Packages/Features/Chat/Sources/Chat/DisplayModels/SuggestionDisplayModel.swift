import CoreModels
import Foundation

/// View-ready row for the Suggestions surface.
public struct SuggestionDisplayModel: Equatable, Sendable, Identifiable {
    public let id: ProfileID
    public let displayName: String
    /// Handle prefixed for display, e.g. `@ava.moreau`.
    public let handleText: String
    /// Why this account is here, in one line.
    public let reasonText: String
    public let monogram: String
    public let avatarURL: URL?
    public let isFollowing: Bool

    public init(account: SuggestedAccount, isFollowing: Bool) {
        id = account.id
        displayName = account.displayName
        handleText = account.handle.isEmpty ? "" : "@\(account.handle)"
        reasonText = Self.reasonText(account.reason)
        monogram = ConversationDisplayModel.monogram(account.displayName)
        avatarURL = account.avatarURL
        self.isFollowing = isFollowing
    }

    static func reasonText(_ reason: SuggestedAccount.Reason) -> String {
        switch reason {
        case .followsYou:
            return "Follows you"
        case .followedBy(let names, let total):
            guard let first = names.first else { return "Suggested for you" }
            let others = total - names.count
            return others > 0 ? "Followed by \(first) + \(others)" : "Followed by \(first)"
        case .suggestedForYou:
            return "Suggested for you"
        }
    }
}
