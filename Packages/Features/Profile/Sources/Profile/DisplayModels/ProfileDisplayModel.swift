import CoreModels
import DesignSystem
import Foundation
import MediaCore
import PostGrid

/// View-ready projection of a `UserProfile`: everything the header renders,
/// pre-formatted so the view does zero business logic.
public struct ProfileDisplayModel: Equatable, Sendable {
    public let id: ProfileID
    /// "@handle" with the sigil applied once, here.
    public let handle: String
    /// The handle line as the header draws it: "@ada · Creator", or a
    /// business's category ("@bakery · Bakery"); the bare handle otherwise.
    public let handleLine: String
    public let displayName: String
    public let bio: String
    public let hasBio: Bool
    public let avatarURL: URL?
    /// One- or two-letter fallback drawn in the avatar circle when there is no
    /// image (or it hasn't loaded).
    public let avatarMonogram: String
    /// The frame over the avatar (#943); nil for none.
    public let avatarFrameID: String?
    public let isVerified: Bool
    /// Abbreviated counts ("1.2K"), or "—" when the counter service was
    /// unreachable — never a misleading "0".
    public let followerText: String?
    public let followingText: String?
    /// Total likes received across the profile's posts (counter.v1's
    /// profile-scoped LIKE). Served only by counter.v1; the column is not
    /// drawn wherever that projection isn't live. Views are not shown — the
    /// header counts likes since 2026-09-30, as every gallery tile does.
    public let likesText: String?
    /// The immersive banner's still: the profile's own banner (`banner_url`
    /// or its media's poster), else its avatar — what every profile without
    /// one has always shown.
    public let bannerImageURL: URL?
    /// The banner's muted loop over that still (#944), nil for a still banner.
    public let bannerVideoURL: URL?
    /// Compact link under the bio, Instagram-style: scheme and "www." stripped
    /// ("ada.dev/notes"). Nil when the profile has no website.
    public let websiteText: String?
    public let websiteURL: URL?

    public init(profile: UserProfile) {
        id = profile.id
        handle = "@" + profile.handle
        handleLine = Self.handleLine(handle: "@" + profile.handle, type: profile.accountType, category: profile.businessCategory)
        displayName = profile.displayName
        bio = profile.bio
        hasBio = !profile.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        avatarURL = profile.avatarURL
        avatarMonogram = MonogramAvatarView.monogram(name: profile.displayName, handle: profile.handle)
        avatarFrameID = profile.avatarFrameID
        isVerified = profile.isVerified
        followerText = Self.format(profile.followerCount)
        followingText = Self.format(profile.followingCount)
        likesText = Self.format(profile.reactionCount)
        // The banner is its own media; it falls back on the avatar only when
        // the avatar is a photo. An animated avatar has none (#1444, the
        // owner's 2026-10-19 call: a separate banner).
        bannerImageURL = profile.bannerURL ?? (AnimatedAvatars.isSheet(profile.avatarURL) ? nil : profile.avatarURL)
        bannerVideoURL = profile.bannerVideoURL
        websiteText = Self.websiteDisplay(profile.websiteURL)
        websiteURL = profile.websiteURL
    }

    static func handleLine(handle: String, type: AccountType, category: String?) -> String {
        switch type {
        case .creator: handle + " · " + AccountType.creator.title
        case .business: handle + " · " + (category ?? AccountType.business.title)
        case .personal, .bot: handle
        }
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

    /// Renders a count estimate: exact → "1.2K", bounded fallback → "1.2K+",
    /// unreadable → "—" (never a misleading "0").
    /// Nil for a counter the backend did not project: the column is then not
    /// drawn, rather than shown with a dash that reads as a defect. See
    /// `HeroStatView.setValue`.
    static func format(_ estimate: CountEstimate) -> String? {
        switch estimate {
        case .exact(let value): abbreviate(value)
        case .atLeast(let value): abbreviate(value) + "+"
        case .unavailable: nil
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

/// What a profile shows before it loads (#1859): the identity the origin
/// knew — its name, handle, avatar and frame — drawn for real, the counters
/// as bones, and nothing reserved that may not exist.
public struct ProfileSeedModel: Equatable, Sendable {
    public let displayName: String
    /// "@handle"; nil while the origin knew only the name.
    public let handle: String?
    public let avatarURL: URL?
    public let avatarMonogram: String
    public let avatarFrameID: String?
    /// Whether the header reserves a banner (with its bone) from the start.
    public let reservesBanner: Bool

    public init(_ stub: ProfileIdentityStub) {
        displayName = stub.displayName
        handle = stub.handle.map { "@" + $0 }
        avatarURL = stub.avatarURL
        avatarMonogram = MonogramAvatarView.monogram(name: stub.displayName, handle: stub.handle ?? "")
        avatarFrameID = stub.avatarFrameID
        reservesBanner = Self.reservesBanner(avatarURL: stub.avatarURL, hasBanner: stub.hasBanner)
    }

    /// ⚠️ THE BANNER IS RESERVED ONLY WHEN IT IS CERTAIN. A photo avatar is
    /// the banner of a profile without one (`ProfileDisplayModel.bannerImageURL`),
    /// so with one the band is there either way; without, only a profile known
    /// to have a banner reserves it. Unknown reserves nothing: a banner that
    /// turns out to exist grows in, rather than a bone that collapses.
    static func reservesBanner(avatarURL: URL?, hasBanner: Bool?) -> Bool {
        if let avatarURL, !AnimatedAvatars.isSheet(avatarURL) { return true }
        return hasBanner == true
    }
}
