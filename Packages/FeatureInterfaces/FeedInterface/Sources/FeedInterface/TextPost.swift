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
}

/// Builds the "+" menu's Text Post screen: a text post's own page with no post
/// behind it yet, which BECOMES that post when its first message is sent.
@MainActor
public protocol TextPostScreenBuilding {
    /// The screen, in its own navigation controller, ready to be presented full
    /// screen. `publisher` is retained for the screen's lifetime.
    func makeTextPostScreen(publisher: any TextPostPublishing) -> UIViewController
}
