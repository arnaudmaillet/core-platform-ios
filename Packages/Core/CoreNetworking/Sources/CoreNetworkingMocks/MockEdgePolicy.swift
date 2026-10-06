import Connect
import Foundation

/// Who may call which RPC — the mock's copy of the backend edge's
/// `EDGE_POLICY` (`dev/GUEST_MODE_REPORT.md` §7.1), so mock mode refuses a
/// guest's write the way the fleet will, instead of passing every gating bug.
///
/// Three kinds of route:
/// - **open**: no session at all — signing in, and starting a guest session;
/// - **guest-readable**: the public reads a guest browses with, and the one
///   write a guest may make (a report, DSA Art. 16);
/// - **member**: everything else — every other write, and every read about
///   the viewer (inbox, notifications, sessions, the account).
///
/// A route not listed is a member route: a new RPC is closed to guests until
/// someone decides otherwise, the edge's own default.
///
/// **The caller**, from the bearer, as the fleet's edge reads its token:
/// - none: **anonymous** — only the open routes, as at the fleet's edge
///   (B1: every read needs `read:public`);
/// - a guest token (`StartGuestSession`, the mock mints them `gt-…`): a
///   **guest** — open and guest-readable routes;
/// - any other token: a **member** — everything.
///
/// Whether a token is still good is `MockAuthService`'s business (refresh,
/// reuse detection), not the edge's — the mock's sessions live in memory, and
/// a token restored from the keychain by a later launch must keep working.
public enum MockEdgePolicy {
    public enum Access: Sendable, Equatable {
        case open
        case guestReadable
        case member
    }

    public enum Caller: Sendable, Equatable {
        case anonymous
        case guest
        case member
    }

    static let openPaths: Set<String> = [
        "/auth.v1.AuthService/Login",
        "/auth.v1.AuthService/Refresh",
        // A guest's read pass, and the App Attest challenge before it (#523).
        "/auth.v1.AuthService/StartGuestSession",
        "/auth.v1.AuthService/StartDeviceAttestation",
    ]

    static let guestReadablePaths: Set<String> = [
        "/post.v1.PostService/GetPost",
        "/post.v1.PostService/ListPostsByProfile",
        "/profile.v1.ProfileService/GetProfileById",
        "/comment.v1.CommentService/ListTopLevel",
        "/comment.v1.CommentService/ListReplies",
        "/counter.v1.CounterService/BatchGetCounters",
        "/social_graph.v1.SocialGraphService/ListFollowers",
        "/social_graph.v1.SocialGraphService/ListFollowing",
        "/geo_discovery.v1.GeoDiscoveryService/QueryTile",
        // Which country location opens — guests too (B10).
        "/geo_discovery.v1.GeoDiscoveryService/GetCountryAccess",
        // For You's Discover, the same pool for guests and members (B3).
        "/timeline.v1.TimelineService/GetDiscoveryFeed",
        "/search.v1.SearchService/Search",
        "/search.v1.SearchService/Suggest",
        "/media.v1.MediaService/ResolveDelivery",
        // The one write open to guests: reporting content (DSA Art. 16), and
        // what became of those reports (`member_or_guest` on the edge).
        "/moderation.v1.ModerationService/SubmitReport",
        "/moderation.v1.ModerationService/ListMyReports",
    ]

    public static func access(for path: String) -> Access {
        if openPaths.contains(path) { return .open }
        if guestReadablePaths.contains(path) { return .guestReadable }
        return .member
    }

    public static func caller(from headers: Headers) -> Caller {
        let bearer = headers.first { $0.key.lowercased() == "authorization" }?.value.first ?? ""
        if bearer.isEmpty { return .anonymous }
        return bearer.hasPrefix("Bearer gt-") ? .guest : .member
    }

    /// The edge's answer: nil lets the call through, an error refuses it —
    /// `unauthenticated`, what the fleet answers a call without the session
    /// the route needs.
    public static func refusal(path: String, headers: Headers) -> ConnectError? {
        let caller = caller(from: headers)
        let needed: Caller
        switch access(for: path) {
        case .open: return nil
        case .guestReadable:
            guard caller == .anonymous else { return nil }
            needed = .guest
        case .member:
            guard caller != .member else { return nil }
            needed = .member
        }
        #if DEBUG
        // The line to look for (`log show`, or Console — NSLog, so it is in
        // the unified log). A guest on a member route: some control is
        // missing its gate (or a screen reads the viewer's data). An
        // anonymous read: the app had no guest token to send.
        NSLog("[edge] REFUSED %@ call to %@", "\(caller)", path)
        #endif
        return ConnectError(
            code: .unauthenticated,
            message: "MockEdgePolicy: \(path) needs a \(needed == .guest ? "guest or member" : "member") session"
        )
    }
}
