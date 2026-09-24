import CoreGraphics
import Foundation

/// The two shapes a profile's banner takes, decided by the picture.
///
/// ```
///   band                                  poster
///   ┌──────────────────────────┐          ┌──────────────────────────┐
///   │ ‹  ▢          [Following]│          │ ‹  ▢          [Following]│
///   │   ~~~ picture ~~~        │          │                          │
///   │        (◯)               │ ← edge   │      ~~~ picture ~~~     │
///   │  ◯  Name                 │          │                          │
///   │     @handle              │          │  (◯)  Name      ░░░░░░░░ │ ← fade
///   │  35    12    3.5K        │          │       @handle   ░░░░░░░░ │
///   │  Bio …                   │          │  35    12    3.5K ▓▓▓▓▓▓ │ ← opaque
///   │  [Edit Profile] [QR] [•] │          │  Bio …                   │
///   └──────────────────────────┘          │  [Edit Profile] [QR] [•] │
///                                         └──────────────────────────┘
/// ```
///
/// **Band** is the social-network header: a short strip across the top, the
/// avatar straddling its bottom edge, the name on the PAGE beneath it. The
/// picture carries no text, so it needs no fade — a clean edge, which the
/// avatar's page-coloured ring cuts through.
///
/// **Poster** is the streaming-app header: the picture runs down to the
/// tray, and the identity lives ON it. Two rules keep that legible: the
/// upper part of the picture is left alone — the subject is visible with
/// nothing over it — and every line of text sits on a run-out to the page's
/// tone that is opaque well before the counters, so the type is page ink on
/// page colour, not ink on a photograph.
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
