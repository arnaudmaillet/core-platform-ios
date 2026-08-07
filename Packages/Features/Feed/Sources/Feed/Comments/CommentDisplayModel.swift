import CoreModels
import Foundation

/// View-ready projection of a `CommentEntry`.
public struct CommentDisplayModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let authorID: ProfileID
    public let authorName: String
    /// The relative time alone — the header shows ONLY the clean display
    /// name beside it (the @handle identifier was removed for reading
    /// comfort; the handle still travels on `CommentEntry` for routing
    /// stubs).
    public let metaText: String
    public let body: String
    /// The two-letter initials — the row's RENDERED identity, drawn
    /// immediately and permanently. The picture (if any) is layered over
    /// it; it is never swapped for it, so there is no empty disc at any
    /// point and no third "loading" state.
    public let monogram: String
    /// The author's picture, hydrated onto `CommentEntry` from profile.v1.
    /// Optional at every step: an unresolved author, an author with no
    /// avatar, and a failed fetch are all the same outcome — the monogram
    /// stands.
    public let avatarURL: URL?
    /// The thread parent's id for level-2 replies; nil at top level.
    public let parentID: String?
    /// Level-2 marker: replies render with the standard reply indentation
    /// (the stream carries exactly two depths — comment.v1's contract).
    public var isReply: Bool { parentID != nil }

    public init(entry: CommentEntry, now: Date = Date()) {
        id = entry.id
        authorID = entry.authorID
        authorName = entry.authorName
        body = entry.body
        parentID = entry.parentID
        monogram = Self.monogram(entry.authorName)
        avatarURL = entry.authorAvatarURL
        metaText = Self.relativeShort(from: entry.createdAt, to: now)
    }

    private static func monogram(_ name: String) -> String {
        let initials = name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
        return initials.isEmpty ? "?" : initials.joined()
    }

    private static func relativeShort(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / 604_800))w"
        }
    }
}
