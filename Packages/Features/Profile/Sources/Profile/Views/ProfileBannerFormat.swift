import CoreGraphics
import Foundation

/// A profile's banner: a BAND — or none.
///
/// ```
///   band
///   ╭──────────────────────────╮
///   │ ‹  ▢          [Following]│
///   │   ~~~ picture ~~~        │
///   │  ◯  Name                 │
///   │ (◯) @handle              │ ← the card's foot
///   ╰──────────────────────────╯
///      ◯  35   12   3.5K
///      Bio …
///      [Edit Profile] [QR] [•]
/// ```
///
/// **Band** is the social-network header: a card across the top (#1208) —
/// the picture behind the chrome and the identity row's top half, the name
/// and the handle on it in its ink (`HeroInk`), its foot ramp in the
/// picture's dark tone. The counters and everything below sit on the page.
///
/// ⚠️ NO POSTER ANY MORE (the owner, 2026-10-15): the tall "cover" banner —
/// a streaming-app stage running under the whole identity block — is gone.
/// Any picture is a band, cropped to it; a profile without one has none.
enum ProfileBannerFormat: Equatable, Sendable {
    case band
    /// No picture at all: the header is the identity block on the page,
    /// starting under the chrome, with no banner drawn and nothing to fade.
    case none

    /// Any picture is a band.
    static func resolved(forImageSize size: CGSize) -> ProfileBannerFormat {
        .band
    }

    /// What a profile shows before its picture has said anything: a band,
    /// the one shape a picture takes.
    static let unresolved: ProfileBannerFormat = .band
}
