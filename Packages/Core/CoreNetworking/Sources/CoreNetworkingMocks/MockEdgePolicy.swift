import Connect
import Foundation

/// Who may call which RPC — the mock's copy of the backend edge's
/// `EDGE_POLICY` (`dev/GUEST_MODE_REPORT.md` §7.1), so mock mode refuses a
/// guest's write the way the fleet will, instead of passing every gating bug.
///
/// Three kinds of route:
/// - **open**: no session at all — signing in;
/// - **guest-readable**: the public reads a guest browses with, and the one
///   write a guest may make (a report, DSA Art. 16);
/// - **member**: everything else — every other write, and every read about
///   the viewer (inbox, notifications, sessions, the account).
///
/// A route not listed is a member route: a new RPC is closed to guests until
/// someone decides otherwise, the edge's own default.
///
/// **The caller.** A request with a bearer token is a member's; one without is
/// a guest's. The guest token (`StartGuestSession`, backend B1) does not exist
/// yet: until it does, a guest is simply a caller with no token. Whether a
/// member's token is still good is `MockAuthService`'s business (refresh,
/// reuse detection), not the edge's — the mock's sessions live in memory, and
/// a token restored from the keychain by a later launch must keep working.
public enum MockEdgePolicy {
    public enum Access: Sendable, Equatable {
        case open
        case guestReadable
        case member
    }

    public enum Caller: Sendable, Equatable {
        case guest
        case member
    }

    static let openPaths: Set<String> = [
        "/auth.v1.AuthService/Login",
        "/auth.v1.AuthService/Refresh",
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
        return bearer.isEmpty ? .guest : .member
    }

    /// The edge's answer: nil lets the call through, an error refuses it —
    /// `unauthenticated`, what the fleet answers a call without a session.
    public static func refusal(path: String, headers: Headers) -> ConnectError? {
        guard access(for: path) == .member, caller(from: headers) == .guest else { return nil }
        #if DEBUG
        // The line to grep for: a guest reached a member route, so some
        // control is missing its gate (or a screen reads the viewer's data).
        print("[edge] REFUSED guest call to \(path)")
        #endif
        return ConnectError(code: .unauthenticated, message: "MockEdgePolicy: \(path) needs a member session")
    }
}
