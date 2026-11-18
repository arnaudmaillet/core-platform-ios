import CoreModels
import Foundation

/// The signed-in viewer's display identity — what the composer needs to
/// render "you" BEFORE you have written anything. A comment carries its
/// author on the way back; the empty composer has no entry to read from,
/// so it asks for this directly.
public struct ViewerIdentity: Equatable, Sendable {
    public let name: String
    /// Optional at every step, exactly like a comment author's: no avatar,
    /// an unresolved profile, and a failed fetch all leave the monogram
    /// standing.
    public let avatarURL: URL?
    /// The profile this identity IS. Nil from a source that knows only a face
    /// — a conversation signs its viewer "You" before it knows more.
    public let profileID: ProfileID?
    public let handle: String

    public init(name: String, avatarURL: URL?, profileID: ProfileID? = nil, handle: String = "") {
        self.name = name
        self.avatarURL = avatarURL
        self.profileID = profileID
        self.handle = handle
    }

    /// This identity as a post's author: what a post written under this face
    /// is published as. Nil without a profile — a face alone authors nothing.
    public var author: AuthorSummary? {
        profileID.map { AuthorSummary(id: $0, handle: handle, displayName: name, avatarURL: avatarURL) }
    }
}
