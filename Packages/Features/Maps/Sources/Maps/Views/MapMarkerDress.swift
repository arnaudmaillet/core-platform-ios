import MapKit
import UIKit

/// What a marker wears AROUND its face: the border, the corner badge and the
/// lock — everything that says where the marker speaks for and whether the
/// viewer may open it, as opposed to the post it shows.
///
/// ```
///   country   flag-gradient border   round flag badge
///   city      flag-gradient border   city badge  (its COUNTRY's flag colours)
///   generic   neutral ring           no badge
///   locked    any of the above, its face darkened under a lock
/// ```
///
/// ⚠️ The flag-gradient borders are EXPERIMENTAL (`-maps-flag-borders`): by
/// default a country and a city wear the neutral ring with their badge.
///
/// One value, resolved by the map and read back off the marker by every
/// transition (`MKMapView.wornDress(for:)`), so the card that flies or the
/// window that opens takes off wearing the marker's exact look.
///
/// The face decides one thing on its own, and the card applies it: a DRESSED
/// icon (an emote or GIF, which has no card around it) wears no border of any
/// kind, only the badge — see `PinCardView.applyFaceVisibility`.
struct MapMarkerDress: Equatable {
    /// The corner badge.
    enum Badge: Equatable {
        /// The country's round flag (ISO 3166-1 alpha-2) — `FlagPalette`.
        case flag(String)
        /// A city: an urban glyph — its country is said by the border.
        case city
        /// A locked country with nothing to show: the lock moves into the
        /// corner, because the flag already IS the face.
        case lock
    }

    /// The corner badge, or none.
    var badge: Badge?
    /// The country whose flag colours paint the border, or nil for the
    /// neutral ring every generic marker has always worn.
    var borderFlag: String?
    /// A locked country's marker: its face darkened, a lock over it, and a tap
    /// that offers the country instead of opening anything.
    var isLocked: Bool

    init(badge: Badge? = nil, borderFlag: String? = nil, isLocked: Bool = false) {
        self.badge = badge
        self.borderFlag = borderFlag
        self.isLocked = isLocked
    }

    /// A marker that speaks for no place: the neutral ring, no badge.
    static let neutral = MapMarkerDress()

    // MARK: - Flag borders (experimental)

    /// ⚠️ EXPERIMENTAL SINCE 2026-10-04: the flag-colour BORDER is behind this
    /// launch argument. Off — the default, and always in Release — every
    /// marker wears the neutral white ring, and only the corner badge says
    /// where it speaks for (a city then names no country). The product call
    /// was white by default, the flag colours kept to try.
    static let flagBordersLaunchArgument = "-maps-flag-borders"

    /// Whether `arguments` ask for flag borders. Release builds never do.
    static func flagBordersEnabled(arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains(flagBordersLaunchArgument)
        #else
        false
        #endif
    }

    /// Whether this process asked for flag borders — the DEFAULT `resolve`
    /// takes; tests pass theirs per call instead (a process-wide switch would
    /// leak across parallel suites).
    static let flagBordersEnabled = flagBordersEnabled(arguments: ProcessInfo.processInfo.arguments)

    /// The dress for a marker at hierarchy depth `kind` (nil: a proximity
    /// cluster or a lone pin) whose posts are in `countryCode`.
    ///
    /// Without a country (a post on the open sea) a place marker falls back to
    /// the neutral look rather than inventing a flag. Without `flagBorders`
    /// (the default — see `flagBordersLaunchArgument`) it keeps its badge and
    /// wears the neutral ring.
    static func resolve(
        kind: MapPlace.Kind?, countryCode: String?, isLocked: Bool,
        flagBorders: Bool = flagBordersEnabled
    ) -> MapMarkerDress {
        guard let kind, let countryCode, !countryCode.isEmpty else {
            return MapMarkerDress(isLocked: isLocked)
        }
        let border = flagBorders ? countryCode : nil
        switch kind {
        case .country:
            return MapMarkerDress(badge: .flag(countryCode), borderFlag: border, isLocked: isLocked)
        case .city:
            return MapMarkerDress(badge: .city, borderFlag: border, isLocked: isLocked)
        }
    }

    /// Where a locked country's post marker stands among the map's
    /// annotations: under every open marker (`.required`), so of two that
    /// collide the one the viewer can open wins, and above every empty
    /// country's flag disc (`CountryFlagAnnotationView`, under `.defaultLow`).
    static let lockedPriority = MKFeatureDisplayPriority.defaultHigh

    /// The same look, openable — what a transition card wears. A locked marker
    /// never opens, so a card that somehow inherited the lock would be
    /// drawing a state no flight can be in.
    var unlocked: MapMarkerDress {
        var dress = self
        dress.isLocked = false
        return dress
    }
}
