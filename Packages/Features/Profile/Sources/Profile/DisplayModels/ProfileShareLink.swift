import Foundation

/// The public web address of a profile.
///
/// Synthesized client-side from the handle, because no service returns one:
/// `profile.v1.ProfileView` carries no canonical URL field, the same gap the
/// feed's share sheet works around (`SnapFeedViewController.presentShareSheet`
/// shares caption + media URL for want of a post URL). When the BFF starts
/// returning a canonical link, this becomes a passthrough and every caller
/// keeps working.
///
/// The host is the single thing to change when the public web domain is
/// settled — it is not read from `AppEnvironment`, which knows only about BFF
/// endpoints (a share link must be the *public* address regardless of which
/// backend the build talks to; a link to `mock.bff.local` would be worse than
/// useless in someone else's Messages thread).
enum ProfileShareLink {
    static let host = "wynn.cn"

    /// `https://wynn.cn/@handle`. Percent-encodes the handle defensively —
    /// handles are validated server-side, but a share link is user-visible
    /// output and must never be a malformed URL.
    static func url(handle: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/@" + handle
        return components.url ?? URL(string: "https://\(host)")!
    }
}
