import CoreModels
import Foundation
import UIKit

/// What a share sheet shares: its subject's name and the line under it, its
/// picture, and its link. A profile's — its display name, its `@handle`, its
/// avatar — or a place's — its name, its country, its round flag
/// (`avatarImage`, a picture with no URL to fetch).
public struct ShareCard: Equatable, @unchecked Sendable {
    public let displayName: String
    /// The line under the name: a profile's handle (with its `@`), a
    /// place's country or continent.
    public let handle: String
    /// The picture punched into the code, fetched — a profile's avatar.
    public let avatarURL: URL?
    /// The picture punched into the code, already in hand — a place's flag.
    /// Wins over `avatarURL`.
    public let avatarImage: UIImage?
    public let url: URL

    public init(displayName: String, handle: String, avatarURL: URL?, avatarImage: UIImage? = nil, url: URL) {
        self.displayName = displayName
        self.handle = handle
        self.avatarURL = avatarURL
        self.avatarImage = avatarImage
        self.url = url
    }
}

/// Someone the viewer can send a profile or a place to, as the share
/// sheet's quick row renders them.
public struct ShareTarget: Equatable, Hashable, Sendable {
    public let id: ProfileID
    public let displayName: String
    public let handle: String
    public let avatarURL: URL?

    public init(id: ProfileID, displayName: String, handle: String, avatarURL: URL?) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
        self.avatarURL = avatarURL
    }
}

/// Supplies the share sheet's quick-send row.
public protocol ShareTargeting: Sendable {
    /// Up to `limit` people, best candidates first. Best-effort: an empty
    /// result leaves the row with just its Search entry rather than failing
    /// the sheet.
    func shareTargets(limit: Int) async -> [ShareTarget]
    /// People matching `query`, for the row's Search entry — the only way to
    /// reach someone the social graph didn't suggest. Best-effort in the same
    /// way; an empty query returns nothing rather than everything.
    func searchTargets(query: String, limit: Int) async -> [ShareTarget]
}

