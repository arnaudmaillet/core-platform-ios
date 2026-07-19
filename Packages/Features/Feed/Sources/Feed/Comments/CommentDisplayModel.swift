import Foundation

/// View-ready projection of a `CommentEntry`.
public struct CommentDisplayModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let authorName: String
    public let metaText: String
    public let body: String
    public let monogram: String
    /// Level-2 marker: replies render with the standard reply indentation
    /// (the stream carries exactly two depths — comment.v1's contract).
    public let isReply: Bool

    public init(entry: CommentEntry, now: Date = Date()) {
        id = entry.id
        authorName = entry.authorName
        body = entry.body
        isReply = entry.parentID != nil
        monogram = Self.monogram(entry.authorName)
        let time = Self.relativeShort(from: entry.createdAt, to: now)
        metaText = entry.authorHandle.isEmpty ? time : "@\(entry.authorHandle) · \(time)"
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
