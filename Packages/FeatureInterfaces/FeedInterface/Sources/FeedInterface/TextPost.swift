import CoreModels
import UIKit

/// Publishes the post the "+" menu's Text Post screen writes.
///
/// Feed draws that screen and Upload owns the pipeline that publishes
/// (`PostComposer`), and neither may import the other — so the screen is handed
/// this instead, the way Chat hands Feed a `ConversationThreadDriving`.
public protocol TextPostPublishing: Sendable {
    /// Creates and publishes a text-only post whose caption is `text`, authored
    /// by `author` — the profile the screen showed as the post's author, so the
    /// post is by whoever the viewer saw it would be by. Nil publishes as the
    /// account's default profile.
    ///
    /// Returns the entry exactly as it was broadcast on `ComposedPostChannel`,
    /// so the screen can become that post without fetching it back. Throws on
    /// any failed step, and nothing is broadcast then.
    func publishTextPost(_ text: String, as author: AuthorSummary?) async throws -> FeedEntry
    /// A voice post (#2209): a text post whose caption is `voice`, with
    /// `text` (possibly empty) under it. The voice is uploaded, then the post
    /// is created with it — never as an attachment, never as its sound.
    func publishTextPost(_ text: String, voice: TextPostVoice?, as author: AuthorSummary?) async throws -> FeedEntry
    /// A showcase (#2216): a text post whose caption's place is `embed`'s
    /// card — a channel's — with `text` above it, standing at `place` on the
    /// map when the author gave one. The embed rides the create request
    /// (`PostEmbedWire`), never as an attachment: the post stays a text post.
    func publishTextPost(
        _ text: String, embed: PostEmbed, place: TextPostPlace?, as author: AuthorSummary?
    ) async throws -> FeedEntry
}

/// Where a showcase stands on the map (#2216): a place the author picked in
/// the text composer — "the Bercy skatepark's channel". Its name is the
/// composer's, the point is what the create request carries
/// (`CreatePostRequest.location`).
public struct TextPostPlace: Sendable, Equatable, Hashable {
    /// What the author picked, as the composer shows it: "Skatepark de Bercy".
    public let name: String
    public let latitude: Double
    public let longitude: Double

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A publisher that sends no embed (fakes, previews): it refuses a showcase
/// rather than posting its words alone.
public struct TextPostEmbedUnsupported: Error, Equatable {
    public init() {}
}

/// A take the text composer records as a post's caption (#2209).
public struct TextPostVoice: Sendable, Equatable {
    public let fileURL: URL
    public let duration: TimeInterval
    /// 100 levels, 0–31.
    public let waveform: [UInt8]

    public init(fileURL: URL, duration: TimeInterval, waveform: [UInt8]) {
        self.fileURL = fileURL
        self.duration = duration
        self.waveform = waveform
    }

    /// The longest a voice post is (#2204): a minute, the last ten seconds
    /// counted down.
    public static let maximumDuration: TimeInterval = 60
}

/// A publisher that sends no voice (fakes, previews).
public struct TextPostVoiceUnsupported: Error, Equatable {
    public init() {}
}

public extension TextPostPublishing {
    func publishTextPost(_ text: String, voice: TextPostVoice?, as author: AuthorSummary?) async throws -> FeedEntry {
        guard voice == nil else { throw TextPostVoiceUnsupported() }
        return try await publishTextPost(text, as: author)
    }

    func publishTextPost(
        _ text: String, embed: PostEmbed, place: TextPostPlace?, as author: AuthorSummary?
    ) async throws -> FeedEntry {
        throw TextPostEmbedUnsupported()
    }
}

/// Builds the "+" menu's Text Post screen: a text post's own page with no post
/// behind it yet, which BECOMES that post when its first message is sent.
@MainActor
public protocol TextPostScreenBuilding {
    /// The screen, in its own navigation controller, ready to be presented full
    /// screen. `publisher` is retained for the screen's lifetime.
    func makeTextPostScreen(publisher: any TextPostPublishing) -> UIViewController
    /// The same screen opened on a showcase (#2216): `embed`'s card attached
    /// under the words — the author may remove it, which publishes a plain
    /// text post — and an optional place.
    func makeTextPostScreen(publisher: any TextPostPublishing, attaching embed: PostEmbed) -> UIViewController
}

public extension TextPostScreenBuilding {
    /// Builders that attach nothing (fakes): the plain screen.
    func makeTextPostScreen(publisher: any TextPostPublishing, attaching embed: PostEmbed) -> UIViewController {
        makeTextPostScreen(publisher: publisher)
    }
}
