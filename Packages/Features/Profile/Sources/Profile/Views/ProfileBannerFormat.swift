import CoreGraphics
import Foundation

/// The two shapes a profile's banner takes, decided by the picture.
///
/// ```
///   band                                  poster
///   ┌──────────────────────────┐          ┌──────────────────────────┐
///   │ ‹  ▢          [Following]│          │ ‹  ▢          [Following]│
///   │   ~~~ picture ~~~        │          │      ~~~ picture ~~~     │
///   │  ◯  Name   ≈≈ blur ≈≈    │          │                          │
///   │ (◯) @handle              │ ← edge   │      ≈≈≈ blur ≈≈≈        │
///   │  ◯  35   12   3.5K       │          │  ◯  Name                 │
///   │  Bio …                   │          │ (◯) @handle   ≈≈ blur ≈≈ │
///   │  [Edit Profile] [QR] [•] │          │  ◯  35   12   3.5K       │
///   └──────────────────────────┘          │  Bio …                   │
///                                         │  [Edit Profile] [QR] [•] │ ← edge
///                                         └──────────────────────────┘
/// ```
///
/// In both, the name and the handle beside the disc's top half stand ON the
/// picture, in its ink (`HeroInk`: white or black by the picture), over its
/// progressively blurred foot, and the page's tone arrives over a short ramp
/// at the edge (`HeroBannerFade`). What differs is the stage and where the
/// edge is:
///
/// **Band** is the social-network header: a short strip across the top — the
/// picture behind the chrome and the identity row's top half, no more. Its
/// edge is the avatar's midline; the counters beside the disc's bottom half
/// and everything below sit on the page, in page ink.
///
/// **Poster** is the streaming-app header: a tall stage of picture under the
/// chrome before the identity (`HeroBannerMetrics.posterStage`), the subject
/// left alone at its top, and the picture running on under the whole block
/// to the tray's foot — the counters, the bio and the link in its ink on it
/// too, the page arriving behind the tray. It fades out as the page scrolls
/// up, gone by the point where a band would hold the avatar, and the ink
/// goes back to the page's with it.
///
/// ⚠️ THE PICTURE DECIDES, NOT A SETTING. A landscape picture is a band, a
/// portrait one a poster: a setting would add a menu and, worse, a picture
/// cropped into the wrong shape. A square is a poster — it is what every
/// banner was before the band existed, and a square cropped to a strip
/// loses the subject's head or feet. The mock corpus seeds all three
/// shapes, so each can be looked at without forcing anything.
enum ProfileBannerFormat: Equatable, Sendable {
    case band
    case poster
    /// No picture at all: the header is the identity block on the page,
    /// starting under the chrome, with no banner drawn and nothing to fade.
    case none

    /// Wider than tall is a band; anything else a poster. The margin keeps a
    /// nearly-square picture a poster, since a strip cropped from it would
    /// keep neither its top nor its bottom.
    static func resolved(forImageSize size: CGSize) -> ProfileBannerFormat {
        guard size.width > 0, size.height > 0 else { return .poster }
        return size.width / size.height > 1.15 ? .band : .poster
    }

    /// What a profile shows before its picture has said anything: the
    /// poster, which is the shape the header had before there were two.
    static let unresolved: ProfileBannerFormat = .poster
}
