import CoreModels
import Foundation

/// Links into the app (#524): the web addresses it shares, opened as
/// universal links, and the same paths on the app's own scheme.
///
///     https://core-platform.click/@kenji.dev     →  .profileHandle("kenji.dev")
///     https://core-platform.click/tag/travel     →  .hashtag("travel")
///     https://core-platform.click/s/Ab3_x-…      →  .profileShareToken("Ab3_x-…")
///     https://core-platform.click/p/post-0042    →  .post("post-0042")
///     https://core-platform.click/family/K7M2…   →  .supervisionInvite("K7M2…")
///     https://core-platform.click/place/country/FR  →  .place(.country(code: "FR"))
///     https://core-platform.click/place/city/48.8566,2.3522?name=Paris&country=FR
///                                                →  .place(.city(…, name: "Paris", countryCode: "FR"))
///     wynn://@kenji.dev, wynn:/tag/travel   (the same paths)
///
/// The web form is what `ProfileShareLink` and a place's share URL already
/// hand out; anything this does not know is nil, and the caller lets it go.
public extension AppRoute {
    /// The host the app's web links live on, and the one place it is set:
    /// share links (`ProfileShareLink`, a place's share URL) build on it, and
    /// it must match the `applinks:` entry in `core-platform-ios.entitlements`
    /// and the domain serving `apple-app-site-association`
    /// (core-platform-infra `global/web/app-site-association`).
    /// `core-platform.click` is a provisional name; changing it means this,
    /// the entitlement and the infra unit's domain together.
    static let webHost = "core-platform.click"
    /// The app's own URL scheme.
    static let appScheme = "wynn"

    init?(deepLink url: URL) {
        guard let parts = Self.pathParts(of: url) else { return nil }
        switch parts.count {
        case 1 where parts[0].hasPrefix("@"):
            guard let handle = Self.handle(String(parts[0].dropFirst())) else { return nil }
            self = .profileHandle(handle)
        case 2 where parts[0].lowercased() == "tag":
            guard let tag = Self.tag(parts[1]) else { return nil }
            self = .hashtag(tag)
        case 2 where parts[0].lowercased() == "s":
            guard let token = Self.shareToken(parts[1]) else { return nil }
            self = .profileShareToken(token)
        case 2 where parts[0].lowercased() == "p":
            guard let id = Self.postID(parts[1]) else { return nil }
            self = .post(PostID(id))
        case 2 where parts[0].lowercased() == "family":
            guard let code = SupervisionInviteCode.normalized(parts[1]) else { return nil }
            self = .supervisionInvite(code)
        case 3 where parts[0].lowercased() == "place":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let place = PlaceLink(path: Array(parts.dropFirst()), query: query) else { return nil }
            self = .place(place)
        default:
            return nil
        }
    }

    /// The path's segments, for a link on the web host or the app's scheme.
    private static func pathParts(of url: URL) -> [String]? {
        let scheme = url.scheme?.lowercased()
        let path: String
        switch scheme {
        case "https", "http":
            guard let host = url.host()?.lowercased(), host == webHost || host == "www." + webHost else { return nil }
            path = url.path(percentEncoded: false)
        case appScheme:
            // Everything after `wynn:`, whatever its slashes: `wynn://@kenji`
            // would otherwise read "@kenji" as an empty user at no host.
            var rest = String(url.absoluteString.dropFirst(appScheme.count + 1))
            if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<cut]) }
            path = rest.removingPercentEncoding ?? rest
        default:
            return nil
        }
        return path.split(separator: "/").map(String.init)
    }

    /// A handle as `profile` stores it: lowercased, 2–30 of `a-z 0-9 . _`.
    private static func handle(_ raw: String) -> String? {
        let handle = raw.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._")
        guard (2...30).contains(handle.count), handle.allSatisfy(allowed.contains) else { return nil }
        return handle
    }

    /// A share token as `profile` issues it: URL-safe base64, kept as is
    /// (case matters). The server checks the exact shape (backend #661).
    private static func shareToken(_ raw: String) -> String? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard (8...64).contains(raw.count), raw.allSatisfy(allowed.contains) else { return nil }
        return raw
    }

    /// A post's link (#1710): `https://core-platform.click/p/<id>` — what a
    /// post's share sheet hands out and its QR code holds.
    static func postLink(_ id: PostID) -> URL? {
        guard postID(id.rawValue) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = webHost
        components.path = "/p/" + id.rawValue
        return components.url
    }

    /// A post id as a link carries it: kept as is, 1–64 of `A-Z a-z 0-9 - _`.
    private static func postID(_ raw: String) -> String? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard (1...64).contains(raw.count), raw.allSatisfy(allowed.contains) else { return nil }
        return raw
    }

    /// A tag as search stores it: lowercased letters, digits and `_`, with a
    /// letter.
    private static func tag(_ raw: String) -> String? {
        let tag = raw.hasPrefix("#") ? String(raw.dropFirst()).lowercased() : raw.lowercased()
        guard !tag.isEmpty, tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), tag.contains(where: \.isLetter)
        else { return nil }
        return tag
    }
}
