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

    /// The badge is the country's ROUND flag, edge to edge in its disc — not
    /// the emoji sitting as a band inside it.
    @Test func theFlagBadgeIsTheRoundFlag() throws {
        let card = card(.media, dress: .resolve(kind: .country, countryCode: "FR", isLocked: false))
        let round = try #require(FlagPalette.roundFlag(for: "FR"))
        let shown = try #require(card.debugBadge.debugImage)
        #expect(shown.pngData() == round.pngData(), "the catalog's round flag, not the emoji")
        #expect(card.debugBadge.debugImageFrame == card.debugBadge.bounds, "the flag fills the badge's disc")
    }

    /// On a SQUARE card (a media marker) the badge sits INSIDE the
    /// bottom-right corner, clear of the border — nothing of it outside the
    /// card.
    @Test func onASquareCardTheBadgeSitsInsideTheCorner() {
        for dress in [MapMarkerDress.resolve(kind: .country, countryCode: "FR", isLocked: false),
                      .resolve(kind: .city, countryCode: "FR", isLocked: false),
                      .resolve(kind: .country, countryCode: "MX", isLocked: true)] {
            let card = card(.media, dress: dress)
            let badge = card.debugBadge.frame
            let clear = MapFlagBorderView.lineWidth + MapMarkerBadgeView.insideGap
            #expect(card.bounds.insetBy(dx: clear - 0.01, dy: clear - 0.01).contains(badge),
                    "\(String(describing: dress.badge)): \(badge) in \(card.bounds)")
            // In the bottom-right corner: past the middle both ways.
            #expect(badge.minX > card.bounds.midX && badge.minY > card.bounds.midY)
            #expect(abs(badge.maxX - (card.bounds.maxX - clear)) < 0.01)
            #expect(abs(badge.maxY - (card.bounds.maxY - clear)) < 0.01)
            #expect(!card.revealStandInOverhangsWindow, "nothing overhangs a window it becomes")
        }
    }

    /// A DISC (a text marker) has no corner to sit in: the badge overlaps its
    /// edge — half outside the card — so the card must not clip it, while the
    /// pictures stay clipped to the card's shape.
    @Test func onADiscTheBadgeOverlapsTheEdgeOutsideTheClip() {
        let card = card(.text, dress: .resolve(kind: .country, countryCode: "FR", isLocked: false))
        let badge = card.debugBadge.frame
        #expect(badge.maxX > card.bounds.maxX && badge.maxY > card.bounds.maxY)
        #expect(badge.minX < card.bounds.maxX && badge.minY < card.bounds.maxY)
        #expect(!card.clipsToBounds)
        #expect(card.debugContentView.clipsToBounds)
        #expect(card.debugContentView.layer.cornerRadius == card.layer.cornerRadius)
        #expect(!card.debugChromeView.clipsToBounds)
        #expect(card.revealStandInOverhangsWindow, "a window must not clip the overhang off")
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

    /// An emote's badge hugs the MARK — on the arc of the disc its square
    /// inscribes, overlapping it like a text disc's — not the square's empty
    /// corner, where it sat apart from the face (Morocco, on the simulator).
    @Test func anEmotesBadgeHugsTheMark() {
        let card = card(.icon, dress: .resolve(kind: .country, countryCode: "MA", isLocked: false))
        card.setIcon((emote(), 0))
        let side = PinCardView.Face.icon.side
        let arc = side / 2 * (1 + 1 / 2.squareRoot())
        #expect(abs(card.debugBadge.center.x - arc) < 0.5 && abs(card.debugBadge.center.y - arc) < 0.5,
                "badge centre \(card.debugBadge.center), arc point \(arc)")
        let text = self.card(.text, dress: .resolve(kind: .country, countryCode: "MA", isLocked: false))
        #expect(abs(card.debugBadge.center.x - text.debugBadge.center.x) < 0.5,
                "the same seat as a text marker's disc of the same side")
        #expect(card.revealStandInOverhangsWindow)
    }

    /// An OPEN emote is drawn at full strength: no dimming, no veil, no lock —
    /// including one whose country was just unlocked.
    @Test func anOpenEmoteIsNotWashedOut() {
        let card = card(.icon, dress: .resolve(kind: .country, countryCode: "MA", isLocked: true))
        card.setIcon((emote(), 0))
        card.setDress(.resolve(kind: .country, countryCode: "MA", isLocked: false))
        #expect(card.debugIconFaceAlpha == 1)
        #expect(card.debugLockVeil.isHidden && card.debugLockGlyph.isHidden)
        #expect(card.alpha == 1)
        let fresh = self.card(.icon, dress: .resolve(kind: .country, countryCode: "MA", isLocked: false))
        fresh.setIcon((emote(), 0))
        #expect(fresh.debugIconFaceAlpha == 1)
        #expect(fresh.debugLockVeil.isHidden && fresh.debugLockGlyph.isHidden)
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

    /// A band's group of one — a country or city with a single post in view —
    /// takes the SAME dress path as a band cluster: its place's flag border
    /// and badge, locked when its country is, never the neutral ring. A local
    /// lone pin stays neutral.
    @Test func aBandsGroupOfOneWearsItsPlacesDress() {
        let france = MapPlace(id: "country:france", name: "France", kind: .country)
        let paris = MapPlace(id: "city:paris", name: "Paris", kind: .city)
        let pins = [
            MapPin(postID: PostID("p-1"), latitude: 48.85, longitude: 2.35, thumbnailURL: nil,
                   kind: .text, places: [paris, france]),
            MapPin(postID: PostID("p-2"), latitude: 40.42, longitude: -3.70, thumbnailURL: nil,
                   kind: .text, places: [MapMockPlaces.spain]),
            MapPin(postID: PostID("p-3"), latitude: 40.50, longitude: -3.60, thumbnailURL: nil,
                   kind: .text, places: [MapMockPlaces.spain]),
        ]
        let items = MapClusterEngine.cluster(pins, zoomScale: 1, cellPoints: 64, viewportDiagonalKm: 2884.3)
        guard let lone = items.first(where: { !$0.isCluster }) else {
            Issue.record("France's single post must still be a marker")
            return
        }
        let single = MapAnnotation(pin: lone.representative, hierarchyKind: lone.hierarchyKind)
        let kind = MapsViewController.dressKind(of: single)
        #expect(kind == .country)

        for locked in [false, true] {
            let view = MapAnnotationView(annotation: single, reuseIdentifier: nil)
            view.configure(
                with: single.pin, dress: .resolve(kind: kind, countryCode: "FR", isLocked: locked),
                imagePipeline: pipeline()
            )
            #expect(view.card.dress.badge == .flag("FR"))
            #expect(view.card.dress.borderFlag == "FR")
            #expect(view.card.dress.isLocked == locked)
            #expect(view.displayPriority == (locked ? MapMarkerDress.lockedPriority : .required))
        }

        // The same path, for a band cluster and for a local lone pin.
        let cluster = MapComputedCluster(items.first { $0.isCluster }!)
        #expect(MapsViewController.dressKind(of: cluster) == .country)
        #expect(MapsViewController.dressKind(of: MapAnnotation(pin: pin("local"))) == nil)
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

/// The flag colours, read off the round flag itself (the emoji for a code the
/// catalog lacks).
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
        #expect(entry.isRound, "read off the round flag, not the emoji")
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
    /// and its ROUND flag from the catalog — no atlas country falls back to
    /// the emoji (`Scripts/import-circle-flags.py` imports exactly the atlas).
    @Test func everyCountryHasARoundFlagAndAPalette() {
        #expect(CountryAtlas.shared.countries.count == 237)
        for country in CountryAtlas.shared.countries {
            let entry = FlagPalette.entry(for: country.code)
            #expect(entry.colors.count >= 2, "\(country.code)")
            #expect(entry.image != nil, "\(country.code)")
            #expect(entry.isRound, "\(country.code) has no round flag in Flags.xcassets")
            if let image = entry.image {
                #expect(image.size == CGSize(width: 40, height: 40), "\(country.code): rendered for the 40pt disc")
            }
        }
    }

    /// A code the catalog has no round flag for (Bonaire is not in the
    /// atlas) still wears its flag: the emoji, drawn and trimmed, with its
    /// colours read off it.
    @Test func aCodeWithoutARoundFlagFallsBackToTheEmoji() {
        #expect(FlagPalette.roundFlag(for: "BQ") == nil)
        let entry = FlagPalette.entry(for: "BQ")
        #expect(!entry.isRound)
        #expect(entry.image != nil)
        #expect(entry.colors.count >= 2)
    }

    /// The round flags are flat artwork: France's white is the flag's own
    /// near-white, not an emoji's shaded grey, and its bands run in order.
    @Test func roundFlagColoursAreTheArtworks() throws {
        let entry = FlagPalette.entry(for: "FR")
        #expect(entry.isRound)
        try #require(entry.colors.count == 3)
        var white: CGFloat = 0
        entry.colors[1].getWhite(&white, alpha: nil)
        #expect(white > 0.9, "white \(white)")
    }
}
