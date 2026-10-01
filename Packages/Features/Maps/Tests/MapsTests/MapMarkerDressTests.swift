import CoreModels
import Foundation
import MapKit
import MediaCore
import Testing
import UIKit
@testable import Maps

/// What a marker wears around its face — the flag border, the corner badge
/// and the lock — per kind (country / city / generic), per face (media / text
/// / emote) and per state (open / locked).
///
/// No `MKMapView` is built here (see `MapAnnotationPopTests` for why): the
/// dress is resolved by a pure function and worn by `PinCardView`, which an
/// annotation view hosts on its own.
@MainActor
struct MapMarkerDressTests {
    private static let side: CGFloat = 56

    private func card(_ face: PinCardView.Face, dress: MapMarkerDress) -> PinCardView {
        let card = PinCardView(frame: CGRect(x: 0, y: 0, width: face.side, height: face.side))
        card.setFace(face)
        card.setDress(dress)
        return card
    }

    /// A 2x2 sheet of one frame: enough to be an emote's art.
    private func emote() -> AnimatedIconArt {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return .sheet(AnimatedIconSheet(sheet: image, frameCount: 1, columns: 1, frameDuration: 0.1))
    }

    // MARK: - Resolving the dress

    @Test func aCountryWearsItsFlagAsBadgeAndBorder() {
        let dress = MapMarkerDress.resolve(kind: .country, countryCode: "FR", isLocked: false)
        #expect(dress.badge == .flag("FR"))
        #expect(dress.borderFlag == "FR")
        #expect(!dress.isLocked)
    }

    /// A city says it is a city in its corner and which country it is in by
    /// its border.
    @Test func aCityWearsTheCityBadgeAndItsCountrysBorder() {
        let dress = MapMarkerDress.resolve(kind: .city, countryCode: "FR", isLocked: false)
        #expect(dress.badge == .city)
        #expect(dress.borderFlag == "FR")
    }

    @Test func aGenericMarkerIsNeutral() {
        #expect(MapMarkerDress.resolve(kind: nil, countryCode: "FR", isLocked: false) == .neutral)
        // A place marker with no country (at sea) invents no flag.
        #expect(MapMarkerDress.resolve(kind: .country, countryCode: "", isLocked: false) == .neutral)
        #expect(MapMarkerDress.resolve(kind: .city, countryCode: nil, isLocked: false) == .neutral)
    }

    /// The lock rides every kind: a locked country's city, country AND lone
    /// pins are all locked.
    @Test func theLockRidesEveryKind() {
        for kind in [MapPlace.Kind.country, .city, nil] {
            #expect(MapMarkerDress.resolve(kind: kind, countryCode: "ES", isLocked: true).isLocked)
        }
        #expect(!MapMarkerDress.resolve(kind: .country, countryCode: "ES", isLocked: true).unlocked.isLocked)
    }

    // MARK: - Tapping

    /// A locked marker OFFERS its country; an open one opens its posts.
    @Test func aLockedMarkerOffersItsCountry() {
        let locked = MapMarkerDress.resolve(kind: .country, countryCode: "ES", isLocked: true)
        #expect(MapsViewController.markerTap(for: locked, countryCode: "ES") == .offer(countryCode: "ES"))
        let lockedPin = MapMarkerDress.resolve(kind: nil, countryCode: "ES", isLocked: true)
        #expect(MapsViewController.markerTap(for: lockedPin, countryCode: "ES") == .offer(countryCode: "ES"))
        let open = MapMarkerDress.resolve(kind: .country, countryCode: "FR", isLocked: false)
        #expect(MapsViewController.markerTap(for: open, countryCode: "FR") == .open)
    }

    // MARK: - Wearing it

    @Test func aCountryCardWearsTheFlagBorderAndBadge() {
        let card = card(.media, dress: .resolve(kind: .country, countryCode: "FR", isLocked: false))
        #expect(!card.debugFlagBorder.isHidden)
        #expect(card.ringView.isHidden, "the flag border replaces the neutral ring, never stacks on it")
        #expect(card.debugFlagBorder.flagCode == "FR")
        #expect(card.debugFlagBorder.debugGradientColors.count >= 4, "two or more colours, each held as a band")
        #expect(!card.debugBadge.isHidden)
        #expect(card.debugBadge.badge == .flag("FR"))
        #expect(card.debugLockVeil.isHidden && card.debugLockGlyph.isHidden)
    }

    @Test func aCityCardWearsTheCityBadgeAndItsCountrysFlagBorder() {
        let card = card(.media, dress: .resolve(kind: .city, countryCode: "DE", isLocked: false))
        #expect(card.debugBadge.badge == .city)
        #expect(!card.debugFlagBorder.isHidden)
        #expect(card.debugFlagBorder.flagCode == "DE")
        #expect(card.debugFlagBorder.debugGradientIsVertical, "Germany's bands run top to bottom")
    }

    @Test func aGenericCardKeepsTheNeutralRingAndNoBadge() {
        let card = card(.media, dress: .neutral)
        #expect(!card.ringView.isHidden)
        #expect(card.debugFlagBorder.isHidden)
        #expect(card.debugBadge.isHidden)
    }

    /// A text face is a framed disc like a photograph: it wears the border.
    @Test func aTextFaceWearsTheBorderOnItsDisc() {
        let card = card(.text, dress: .resolve(kind: .country, countryCode: "JP", isLocked: false))
        #expect(!card.debugFlagBorder.isHidden)
        #expect(card.debugBadge.badge == .flag("JP"))
    }

    /// An EMOTE has no card to frame: the flag in its corner, no border of
    /// any kind.
    @Test func anEmoteWearsOnlyTheBadge() {
        let card = card(.icon, dress: .resolve(kind: .country, countryCode: "FR", isLocked: false))
        card.setIcon((emote(), 0))
        #expect(card.debugFlagBorder.isHidden, "no flag border around an emote")
        #expect(card.ringView.isHidden, "nor the neutral one")
        #expect(!card.debugBadge.isHidden)
        #expect(card.debugBadge.badge == .flag("FR"))
    }

    /// The badge overlaps the corner — half outside the card — so the card must
    /// not clip it, while the pictures stay clipped to the card's shape.
    @Test func theBadgeOverlapsTheCornerOutsideTheClip() {
        let card = card(.media, dress: .resolve(kind: .country, countryCode: "FR", isLocked: false))
        let badge = card.debugBadge.frame
        #expect(badge.maxX > card.bounds.maxX && badge.maxY > card.bounds.maxY)
        #expect(badge.minX < card.bounds.maxX && badge.minY < card.bounds.maxY)
        #expect(!card.clipsToBounds)
        #expect(card.debugContentView.clipsToBounds)
        #expect(card.debugContentView.layer.cornerRadius == card.layer.cornerRadius)
        #expect(!card.debugChromeView.clipsToBounds)
    }

    /// The badge and the flag border are the flight's resting chrome, so they
    /// fade with the ring as the card leaves the marker; the reveal's content
    /// channel fades them too.
    @Test func theFurnitureLeavesWithTheRing() {
        let card = card(.media, dress: .resolve(kind: .country, countryCode: "FR", isLocked: false))
        let chrome = try? #require(card.zoomRestingChrome)
        #expect(chrome === card.debugChromeView)
        #expect(card.debugBadge.isDescendant(of: card.debugChromeView))
        #expect(card.debugFlagBorder.isDescendant(of: card.debugChromeView))
        card.setContentOpacity(0.5)
        #expect(abs(card.debugBadge.alpha - 0.5) < 0.001)
        #expect(abs(card.debugFlagBorder.alpha - 0.5) < 0.001)
    }

    /// The badge keeps its corner as the card grows into a flight.
    @Test func theBadgeRidesTheCornerAsTheCardGrows() {
        let card = card(.media, dress: .resolve(kind: .country, countryCode: "FR", isLocked: false))
        let before = card.bounds.maxX - card.debugBadge.center.x
        card.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        #expect(abs((card.bounds.maxX - card.debugBadge.center.x) - before) < 0.5, // autoresizing rounds to the pixel
                "before \(before) after \(card.bounds.maxX - card.debugBadge.center.x) chrome \(card.debugChromeView.frame) badge \(card.debugBadge.frame)")
        #expect(card.debugBadge.bounds.width == MapMarkerBadgeView.side, "its own size, not the card's")
    }

    // MARK: - Locked

    @Test func aLockedMediaCardIsDarkenedUnderALock() {
        let card = card(.media, dress: .resolve(kind: .country, countryCode: "ES", isLocked: true))
        #expect(!card.debugLockVeil.isHidden)
        #expect(!card.debugLockGlyph.isHidden)
        #expect(card.debugBadge.badge == .flag("ES"), "the flag stays in the corner")
        #expect(!card.debugFlagBorder.isHidden)
    }

    /// A locked emote has no ground to darken: the mark dims, the lock sits
    /// over it, and there is still no border.
    @Test func aLockedEmoteDimsTheMark() {
        let card = card(.icon, dress: .resolve(kind: .country, countryCode: "ES", isLocked: true))
        card.setIcon((emote(), 0))
        #expect(card.debugLockVeil.isHidden, "a veil would draw the square the emote has no right to")
        #expect(!card.debugLockGlyph.isHidden)
        #expect(card.debugIconFaceAlpha < 1)
        #expect(card.debugFlagBorder.isHidden)
    }

    @Test func unlockingTakesTheLockOff() {
        let card = card(.media, dress: .resolve(kind: .country, countryCode: "ES", isLocked: true))
        card.setDress(.resolve(kind: .country, countryCode: "ES", isLocked: false))
        #expect(card.debugLockVeil.isHidden && card.debugLockGlyph.isHidden)
    }

    // MARK: - The annotation views

    private func pin(_ id: String, kind: MapPin.Kind = .photo) -> MapPin {
        MapPin(
            postID: PostID(id), latitude: 48.8566, longitude: 2.3522,
            thumbnailURL: kind == .text ? nil : URL(string: "mock://media/\(id)"), kind: kind
        )
    }

    private func pipeline() -> ImagePipeline { ImagePipeline(fetcher: PlaceholderImageFetcher()) }

    /// The DEBUG banding square is gone: a country cluster's view draws no
    /// border of its own, only the card's flag border.
    @Test func aCountryClusterDrawsNoDebugSquare() {
        let place = MapPlace(id: "country:france", name: "France", kind: .country)
        let item = MapClusterEngine.Item(
            representative: pin("a"), memberIDs: [PostID("a"), PostID("b")],
            latitude: 48.8566, longitude: 2.3522, place: place, isHierarchyMarker: true
        )
        let cluster = MapComputedCluster(item)
        let view = MapClusterAnnotationView(annotation: cluster, reuseIdentifier: nil)
        view.configure(
            with: cluster, dress: .resolve(kind: .country, countryCode: "FR", isLocked: false),
            imagePipeline: pipeline()
        )
        #expect(view.layer.borderWidth == 0)
        #expect(view.card.dress.badge == .flag("FR"))
        #expect(view.displayPriority == .required)
    }

    /// A locked marker gives way to an open one where they collide, and goes
    /// back to `.required` when its country opens.
    @Test func aLockedMarkerGivesWay() {
        let view = MapAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.configure(
            with: pin("v", kind: .video), dress: .resolve(kind: nil, countryCode: "ES", isLocked: true),
            imagePipeline: pipeline()
        )
        #expect(view.displayPriority == MapMarkerDress.lockedPriority)
        #expect(view.displayPriority.rawValue < MKFeatureDisplayPriority.required.rawValue)
        #expect(view.card.dress.isLocked)
        view.configure(
            with: pin("v", kind: .video), dress: .resolve(kind: nil, countryCode: "ES", isLocked: false),
            imagePipeline: pipeline()
        )
        #expect(view.displayPriority == .required)
        #expect(!view.card.dress.isLocked, "the dress is re-applied above the idempotence guard")
    }

    /// Recycled views take their dress off.
    @Test func reuseStripsTheDress() {
        let view = MapAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.configure(
            with: pin("a"), dress: .resolve(kind: nil, countryCode: "ES", isLocked: true),
            imagePipeline: pipeline()
        )
        view.prepareForReuse()
        #expect(view.card.dress == .neutral)
        #expect(view.card.debugLockVeil.isHidden)
    }
}

/// The flag colours, read off the emoji itself.
@MainActor
struct FlagPaletteTests {
    private func hsb(_ color: UIColor) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return (h, s, b)
    }

    private func isWhite(_ c: UIColor) -> Bool { let v = hsb(c); return v.s < 0.15 && v.b > 0.85 }
    private func isRed(_ c: UIColor) -> Bool { let v = hsb(c); return (v.h < 0.05 || v.h > 0.93) && v.s > 0.5 }
    private func isBlue(_ c: UIColor) -> Bool { let v = hsb(c); return v.h > 0.55 && v.h < 0.72 && v.s > 0.4 }

    @Test(arguments: ["FR", "JP", "DE", "US", "BR", "CH"])
    func aFlagGivesTwoOrMoreColours(_ code: String) {
        let entry = FlagPalette.entry(for: code)
        #expect(entry.colors.count >= 2, "\(code) gave \(entry.colors.count)")
        #expect(entry.colors.count <= 3)
        #expect(entry.image != nil)
    }

    /// France reads as it flies: blue, white, red, left to right.
    @Test func franceReadsBlueWhiteRedLeftToRight() {
        let entry = FlagPalette.entry(for: "FR")
        #expect(entry.axis == .horizontal)
        #expect(entry.colors.count == 3)
        guard entry.colors.count == 3 else { return }
        #expect(isBlue(entry.colors[0]))
        #expect(isWhite(entry.colors[1]))
        #expect(isRed(entry.colors[2]))
    }

    /// Japan is a low-saturation flag — mostly white — and still gives its
    /// red, and keeps its white (the hairline makes it visible on the map).
    @Test func japanKeepsItsWhiteAndItsRed() {
        let colors = FlagPalette.colors(for: "JP")
        #expect(colors.contains(where: isWhite))
        #expect(colors.contains(where: isRed))
    }

    @Test func germanyRunsTopToBottom() {
        #expect(FlagPalette.entry(for: "DE").axis == .vertical)
    }

    /// Rendered once per country.
    @Test func aFlagIsRenderedOnce() {
        let first = FlagPalette.entry(for: "BR")
        let count = FlagPalette.renderCount
        let second = FlagPalette.entry(for: "br")
        #expect(FlagPalette.renderCount == count, "the second ask was a cache hit")
        #expect(first.image === second.image)
    }

    /// Every country the atlas draws gets a border of at least two colours
    /// and a picture for its badge.
    @Test func everyCountryHasAPalette() {
        for country in CountryAtlas.shared.countries {
            let entry = FlagPalette.entry(for: country.code)
            #expect(entry.colors.count >= 2, "\(country.code)")
            #expect(entry.image != nil, "\(country.code)")
        }
    }
}
