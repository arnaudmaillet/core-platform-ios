import MapKit
import Testing
@testable import Maps

/// The renderers the map asks for every country.
@MainActor
struct CountryLayerTests {
    /// MapKit builds a renderer through `init(overlay:)` from inside its own
    /// initialisers; a subclass missing it traps on the first draw.
    @Test func aCountryGetsARenderer() throws {
        let france = try #require(CountryAtlas.shared.country(code: "FR"))
        let layer = CountryLayer()
        let renderer = try #require(layer.renderer(for: CountryShape(country: france)) as? CountryRenderer)
        #expect(renderer.style == .unlocked)
        #expect(renderer.lineWidth == 1)
        let lifted = CountryRenderer(shape: CountryShape(country: france, lifted: true))
        #expect(lifted.lineWidth == 1.5, "a rim, not a marker stroke")
    }

    /// The lift is the copy's opacity: 0 is invisible, 1 fully risen.
    @Test func theLiftFadesTheCopy() throws {
        let france = try #require(CountryAtlas.shared.country(code: "FR"))
        let lifted = CountryRenderer(shape: CountryShape(country: france, lifted: true))
        #expect(lifted.lift == 1 && lifted.alpha == 1)
        lifted.lift = 0
        #expect(lifted.alpha == 0)
        lifted.lift = 0.5
        #expect(lifted.alpha == 0.5)
    }

    /// A disc's view carries an empty margin MapKit collides on, but only
    /// the disc itself takes a touch.
    @Test func aFlagDiscKeepsItsDistanceButOnlyItsBodyIsTappable() throws {
        let spain = try #require(CountryAtlas.shared.country(code: "ES"))
        let flag = CountryFlagAnnotation(country: spain, isLocked: true, rank: 4)
        let view = CountryFlagAnnotationView(annotation: flag, reuseIdentifier: nil)
        let margin = CountryFlagAnnotationView.collisionMargin
        #expect(view.bounds.width > 2 * margin.width && view.bounds.height > 2 * margin.height)
        #expect(!view.point(inside: CGPoint(x: 2, y: 2), with: nil), "the margin is empty map")
        #expect(view.point(inside: CGPoint(x: view.bounds.midX, y: view.bounds.midY), with: nil))
    }

    /// An empty country's disc IS its round flag, edge to edge — darkened with
    /// a lock in its corner when locked, plain when open — and it gives way to
    /// every post marker.
    @Test func anEmptyCountryWearsItsFlag() throws {
        let japan = try #require(CountryAtlas.shared.country(code: "JP"))
        let round = try #require(FlagPalette.roundFlag(for: "JP"))
        let locked = CountryFlagAnnotationView(
            annotation: CountryFlagAnnotation(country: japan, isLocked: true, rank: 12), reuseIdentifier: nil
        )
        #expect(locked.debugIsDarkened)
        #expect(locked.debugVeilAlpha == CountryFlagAnnotationView.lockedVeilAlpha)
        #expect(locked.debugBadge == .lock)
        #expect(locked.debugFlagImage?.pngData() == round.pngData(), "the round flag, not the emoji")
        #expect(locked.debugFlagFrame == locked.debugDiscBounds, "the disc is the flag")
        let open = CountryFlagAnnotationView(
            annotation: CountryFlagAnnotation(country: japan, isLocked: false, rank: 12), reuseIdentifier: nil
        )
        #expect(!open.debugIsDarkened)
        #expect(open.debugBadge == nil)
        #expect(open.debugFlagImage?.pngData() == round.pngData())
        #expect(open.debugFlagFrame == open.debugDiscBounds)
        #expect(open.debugDiscBounds.width == CountryFlagAnnotationView.side)
        // Under every post marker, open or locked; the busier, the higher.
        #expect(open.displayPriority.rawValue < MapMarkerDress.lockedPriority.rawValue)
        #expect(CountryFlagAnnotationView.priority(forRank: 1).rawValue
                > CountryFlagAnnotationView.priority(forRank: 40).rawValue)
    }

    /// Tapping a locked disc OFFERS the country; an open one is shown.
    @Test func tappingALockedDiscOffersTheCountry() throws {
        let spain = try #require(CountryAtlas.shared.country(code: "ES"))
        let layer = CountryLayer()
        var offered: String?
        var shown: String?
        layer.onLockedCountryTapped = { offered = $0.code }
        layer.onCountryTapped = { shown = $0.code }
        let view = CountryFlagAnnotationView(annotation: nil, reuseIdentifier: nil)
        layer.configure(view, for: CountryFlagAnnotation(country: spain, isLocked: true, rank: 4))
        view.onSelect?()
        #expect(offered == "ES")
        #expect(shown == nil)
        layer.configure(view, for: CountryFlagAnnotation(country: spain, isLocked: false, rank: 4))
        view.onSelect?()
        #expect(shown == "ES")
    }

    /// A country a post marker stands for wears no disc; every other one
    /// does, locked or open as the account has it.
    @Test func onlyCountriesWithoutAMarkerWearADisc() throws {
        let layer = CountryLayer()
        layer.access = FakeAccess()
        let france = try #require(CountryAtlas.shared.country(code: "FR"))
        let spain = try #require(CountryAtlas.shared.country(code: "ES"))
        let japan = try #require(CountryAtlas.shared.country(code: "JP"))
        layer.setCountriesWithMarkers(["FR"])
        #expect(layer.wantsFlag(for: france) == nil)
        #expect(layer.wantsFlag(for: spain)?.isLocked == true)
        #expect(layer.wantsFlag(for: spain)?.rank == 2, "the standing's rank")
        #expect(layer.wantsFlag(for: japan)?.isLocked == true)
        layer.setCountriesWithMarkers(["ES"])
        #expect(layer.wantsFlag(for: france)?.isLocked == false, "home: open")
        #expect(layer.wantsFlag(for: spain) == nil)
    }

    private final class FakeAccess: CountryAccess {
        let homeCountry = "FR"
        let gems = 0
        func isUnlocked(_ code: String) -> Bool { code == "FR" }
        func standing(of code: String) -> CountryStanding? {
            code == "ES" ? CountryStanding(code: "ES", rank: 2, likes: 10, posts: 3, price: 50) : nil
        }
        func standings() -> [CountryStanding] { [] }
        func unlock(_ code: String) -> CountryUnlockOutcome { .unknownCountry }
    }
}
