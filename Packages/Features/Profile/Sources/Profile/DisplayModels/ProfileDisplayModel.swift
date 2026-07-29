import CoreModels
import Foundation
import PostGrid

/// View-ready projection of a `UserProfile`: everything the header renders,
/// pre-formatted so the view does zero business logic.
public struct ProfileDisplayModel: Equatable, Sendable {
    public let id: ProfileID
    /// "@handle" with the sigil applied once, here.
    public let handle: String
    public let displayName: String
    public let bio: String
    public let hasBio: Bool
    public let avatarURL: URL?
    /// One- or two-letter fallback drawn in the avatar circle when there is no
    /// image (or it hasn't loaded).
    public let avatarMonogram: String
    public let isVerified: Bool
    /// Abbreviated counts ("1.2K"), or "—" when the counter service was
    /// unreachable — never a misleading "0".
    public let followerText: String
    public let followingText: String
    /// Total reactions received across the profile's posts. Served only by
    /// counter.v1; "—" wherever that projection isn't live.
    public let reactionsText: String
    /// Total content views. Served only by counter.v1; "—" wherever that
    /// projection isn't live (it isn't on the fleet or the mock today).
    public let viewsText: String
    /// The immersive banner's media. profile.v1 has no dedicated cover asset
    /// yet, so this mirrors the avatar image until the contract grows one —
    /// swap the source here, and the header needs no change.
    public let bannerImageURL: URL?
    /// Compact link under the bio, Instagram-style: scheme and "www." stripped
    /// ("ada.dev/notes"). Nil when the profile has no website.
    public let websiteText: String?
    public let websiteURL: URL?

    public init(profile: UserProfile) {
        id = profile.id
        handle = "@" + profile.handle
        displayName = profile.displayName
        bio = profile.bio
        hasBio = !profile.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        avatarURL = profile.avatarURL
        avatarMonogram = Self.monogram(displayName: profile.displayName, handle: profile.handle)
        isVerified = profile.isVerified
        followerText = Self.format(profile.followerCount)
        followingText = Self.format(profile.followingCount)
        reactionsText = Self.format(profile.reactionCount)
        viewsText = Self.format(profile.viewCount)
        bannerImageURL = profile.avatarURL
        websiteText = Self.websiteDisplay(profile.websiteURL)
        websiteURL = profile.websiteURL
    }

    /// "https://www.ada.dev/notes/" → "ada.dev/notes".
    static func websiteDisplay(_ url: URL?) -> String? {
        guard let url else { return nil }
        var host = url.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst("www.".count) }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        let display = host + path
        return display.isEmpty ? nil : display
    }

    private static func monogram(displayName: String, handle: String) -> String {
        let source = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? handle : displayName
        let initials = source
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(Character.uppercased) }
        return initials.isEmpty ? "?" : initials.joined()
    }

    /// Renders a count estimate: exact → "1.2K", bounded fallback → "1.2K+",
    /// unreadable → "—" (never a misleading "0").
    static func format(_ estimate: CountEstimate) -> String {
        switch estimate {
        case .exact(let value): abbreviate(value)
        case .atLeast(let value): abbreviate(value) + "+"
        case .unavailable: "—"
        }
    }

    /// 1234 → "1.2K", 1_500_000 → "1.5M".
    ///
    /// Delegates to `PostGridCount` so the header's counter row and the grid
    /// cells' metadata line cannot disagree about how a number is spelled —
    /// they render the same counters side by side on this screen.
    static func abbreviate(_ value: Int64) -> String {
        PostGridCount.abbreviate(value)
    }
}

private extension Character {
    static func uppercased(_ character: Character) -> String {
        character.uppercased()
    }
}
