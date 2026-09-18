import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// What the look cards are DRAWN FROM: the reference photograph on a video, the
/// author's own picture on a photograph.
///
/// ⚠️ **THE STUB LIBRARY VENDS ONE FLAT COLOUR PER PAGE, AND THAT IS THE
/// INSTRUMENT.** It stands in for the poster a clip's cards used to be dressed
/// from — flat is what a poster routinely is, and it is the whole reason for
/// this slice. A card drawn from a flat colour is that colour; a card drawn from
/// a photograph is not. One pixel tells them apart, and
/// `PixelProbe.distance` reads all sixty-four.
///
/// ⚠️ **AND EVERY EXPECTATION IS RENDERED BY THE SAME TWO CALLS AS THE CARD
/// ITSELF** (`MediaLookThumbnails.base` then `.dressed`). The pipeline is
/// therefore NOT what these tests are about — it cancels on both sides — and the
/// SOURCE picture is the only thing left that can make them differ. Each test
/// says both halves: this card IS the reference's, and it is NOT the page
/// picture's.
@MainActor
struct MediaLookReferenceTests {
    typealias Harness = MediaEditorEffectsTests

    /// The flat colour each page's own picture is, per id — a clip's poster and
    /// a photograph's picture, told apart so a card can name which one dressed
    /// it.
    private static func pageColour(for id: String) -> UIColor {
        id.hasPrefix("video") ? Harness.pagePictureColour : UIColor(red: 0.1, green: 0.25, blue: 0.9, alpha: 1)
    }

    private final class StubLibrary: MediaLibraryReading {
        var access: MediaLibraryAccess { .granted }
        func requestAccess() async -> MediaLibraryAccess { .granted }
        func presentLimitedPicker(from host: UIViewController) {}
        func albums() async -> [MediaLibraryAlbum] { [] }
        func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] { [] }

        func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
            MediaEditorEffectsTests.flat(MediaLookReferenceTests.pageColour(for: item))
        }

        func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
            FileManager.default.temporaryDirectory.appendingPathComponent("\(item).mov")
        }
    }

    struct Screen {
        let editor: MediaEditorViewController
        let window: UIWindow
    }

    /// `kinds` in the order they are paged through — `true` for a video.
    private static func open(_ kinds: [Bool]) -> Screen {
        let items = kinds.enumerated().map { index, video in
            MediaLibraryItem(
                id: video ? "video-\(index)" : "photo-\(index)",
                kind: video ? .video(duration: 9) : .photo
            )
        }
        let editor = MediaEditorViewController(
            items: items, library: StubLibrary(), preview: Harness.StubPreview()
        ) { _, _ in UIViewController() }
        let navigation = UINavigationController(rootViewController: editor)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        editor.beginAppearanceTransition(true, animated: false)
        editor.endAppearanceTransition()
        window.layoutIfNeeded()
        return Screen(editor: editor, window: window)
    }

    private static func openEffects(on screen: Screen) throws -> MediaEffectsToolsView {
        screen.editor.debugTapCategory("Effects")
        screen.window.layoutIfNeeded()
        return try #require(screen.editor.debugBand.content as? MediaEffectsToolsView)
    }

    private static func openFilters(on screen: Screen) throws -> MediaFilterRowView {
        screen.editor.debugChoose("Filters")
        screen.window.layoutIfNeeded()
        return try #require(screen.editor.debugBand.content as? MediaFilterRowView)
    }

    /// A chip or a pill as it should be: `source` through the two calls the
    /// modes make, wearing `look`.
    private static func card(
        from source: UIImage, crop: MediaCrop = .untouched, side: CGFloat, scale: CGFloat,
        wearing look: FrameLook = .neutral
    ) -> UIImage {
        let base = MediaLookThumbnails.base(source, crop: crop, pixels: side * max(1, scale))
        return MediaLookThumbnails.dressed(base, in: look)
    }

    // MARK: - The resource

    /// ⚠️ **A MISSING BUNDLE RESOURCE IS A SILENT BLANK CARD.** `Bundle.module`
    /// answers nil for a file the manifest forgot, the modes fall back to the
    /// page's own picture, and the only symptom is the bug this slice fixes
    /// coming back. So the resource is asserted on directly — that it is there,
    /// that it has pixels, and that it is a PHOTOGRAPH rather than a blank or a
    /// flat placeholder.
    @Test func theReferencePhotographIsInTheBundle() throws {
        let picture = try #require(
            MediaLookReference.picture,
            "Upload's bundle has no LookReference/filter-reference.jpg — check Package.swift's resources"
        )
        #expect(picture.size.width >= 400 && picture.size.height >= 400, "got \(picture.size)")
        #expect(PixelProbe.spread(picture) > 0.2,
                "the reference is one flat colour, which is what it exists to replace")
    }

    @Test func aVideoStandsInForItsOwnFilmAndAPhotographDoesNot() {
        #expect(MediaLookReference.standsIn(for: MediaLibraryItem(id: "v", kind: .video(duration: 3))))
        #expect(!MediaLookReference.standsIn(for: MediaLibraryItem(id: "p", kind: .photo)))
        #expect(!MediaLookReference.standsIn(for: nil), "no page is not a video")
    }

    // MARK: - A video

    @Test func aVideosFilterChipsAreTheReferenceAndNotItsPoster() async throws {
        let screen = Self.open([true])
        let reference = try #require(MediaLookReference.picture)
        let row = try Self.openFilters(on: screen)
        // ⚠️ **NOT AN ASSERTION ABOUT SPEED, BUT ABOUT WHAT LANDS.** The
        // reference needs no fetch and dresses the row in the same turn, while
        // the page's own picture arrives on the library's turn. Waiting for a
        // chip to exist at all is what makes the pixel read below the thing
        // that fails when the wrong source is used, rather than a nil picture.
        try await Harness.settle(until: { row.debugPicture(for: .original) != nil })
        let chip = try #require(row.debugPicture(for: .original))

        let scale = row.traitCollection.displayScale
        let side = MediaFilterRowView.thumbnailSide
        let fromReference = Self.card(from: reference, side: side, scale: scale)
        let fromPoster = Self.card(
            from: Harness.flat(Self.pageColour(for: "video-0")), side: side, scale: scale
        )
        #expect(PixelProbe.distance(chip, fromReference) < 0.02, "the chip is not the reference photograph")
        #expect(PixelProbe.distance(chip, fromPoster) > 0.2, "the chip is still the clip's poster")
    }

    @Test func aVideosEffectCardsAreTheReferenceAndNotItsPoster() async throws {
        let screen = Self.open([true])
        let reference = try #require(MediaLookReference.picture)
        let tools = try Self.openEffects(on: screen)
        try await Harness.settle(until: { screen.editor.effectsMode.debugCardsAreDressed })
        let card = try #require(tools.debugPicture(for: .blur))

        let scale = tools.traitCollection.displayScale
        let side = MediaEffectsToolsView.thumbnailSide
        var look = FrameLook.neutral
        look.effect = LookEffect(kind: .blur, intensity: MediaEffectsCatalog.previewIntensity)
        let fromReference = Self.card(from: reference, side: side, scale: scale, wearing: look)
        let fromPoster = Self.card(
            from: Harness.flat(Self.pageColour(for: "video-0")), side: side, scale: scale, wearing: look
        )
        #expect(PixelProbe.distance(card, fromReference) < 0.02, "the pill is not the reference photograph")
        #expect(PixelProbe.distance(card, fromPoster) > 0.2, "the pill is still the clip's poster")
    }

    /// ⚠️ **THE AUTHOR'S CROP CUTS THE AUTHOR'S FILM, AND NOTHING ELSE.** A crop
    /// taken from the reference would throw away part of the spectrum the cards
    /// are read against and claim a framing these pixels know nothing about —
    /// so a video wearing a hard crop gets the WHOLE reference, while its page
    /// above is cut as it always was.
    @Test func aCroppedVideoStillGetsTheWholeReference() async throws {
        let screen = Self.open([true])
        let reference = try #require(MediaLookReference.picture)
        screen.editor.change("video-0") {
            $0.crop = MediaCrop(rect: CGRect(x: 0, y: 0, width: 0.35, height: 0.35))
        }
        let row = try Self.openFilters(on: screen)
        // ⚠️ **NOT AN ASSERTION ABOUT SPEED, BUT ABOUT WHAT LANDS.** The
        // reference needs no fetch and dresses the row in the same turn, while
        // the page's own picture arrives on the library's turn. Waiting for a
        // chip to exist at all is what makes the pixel read below the thing
        // that fails when the wrong source is used, rather than a nil picture.
        try await Harness.settle(until: { row.debugPicture(for: .original) != nil })
        let chip = try #require(row.debugPicture(for: .original))

        let scale = row.traitCollection.displayScale
        let side = MediaFilterRowView.thumbnailSide
        let whole = Self.card(from: reference, side: side, scale: scale)
        let cut = Self.card(
            from: reference, crop: MediaCrop(rect: CGRect(x: 0, y: 0, width: 0.35, height: 0.35)),
            side: side, scale: scale
        )
        #expect(PixelProbe.distance(whole, cut) > 0.1, "guard: this crop changes nothing to read")
        #expect(PixelProbe.distance(chip, whole) < 0.02, "the chip's reference was cut by the author's crop")

        // ⚠️ **AND THE SAME ANSWER IN THE OTHER ROW.** The two modes cut their
        // cards in two different files; one of them obeying this rule says
        // nothing about the other.
        let tools = try Self.openEffects(on: screen)
        try await Harness.settle(until: { screen.editor.effectsMode.debugCardsAreDressed })
        let pill = try #require(tools.debugPicture(for: .blur))
        var look = FrameLook.neutral
        look.effect = LookEffect(kind: .blur, intensity: MediaEffectsCatalog.previewIntensity)
        let pillSide = MediaEffectsToolsView.thumbnailSide
        let pillScale = tools.traitCollection.displayScale
        #expect(
            PixelProbe.distance(
                pill, Self.card(from: reference, side: pillSide, scale: pillScale, wearing: look)
            ) < 0.02,
            "the pill's reference was cut by the author's crop"
        )
    }

    // MARK: - A photograph

    @Test func aPhotographKeepsItsOwnPictureInBothRows() async throws {
        let screen = Self.open([false])
        let own = Harness.flat(Self.pageColour(for: "photo-0"))
        let reference = try #require(MediaLookReference.picture)
        // The page's own picture is fetched, so the chips wait for it; the
        // reference never does, which is half of what this test is about.
        try await Harness.settle(until: { screen.editor.heldPicture?.id == "photo-0" })

        let row = try Self.openFilters(on: screen)
        // ⚠️ **NOT AN ASSERTION ABOUT SPEED, BUT ABOUT WHAT LANDS.** The
        // reference needs no fetch and dresses the row in the same turn, while
        // the page's own picture arrives on the library's turn. Waiting for a
        // chip to exist at all is what makes the pixel read below the thing
        // that fails when the wrong source is used, rather than a nil picture.
        try await Harness.settle(until: { row.debugPicture(for: .original) != nil })
        let chip = try #require(row.debugPicture(for: .original))
        let chipScale = row.traitCollection.displayScale
        #expect(
            PixelProbe.distance(
                chip, Self.card(from: own, side: MediaFilterRowView.thumbnailSide, scale: chipScale)
            ) < 0.02,
            "the chip is not the author's own picture"
        )
        #expect(
            PixelProbe.distance(
                chip, Self.card(from: reference, side: MediaFilterRowView.thumbnailSide, scale: chipScale)
            ) > 0.2,
            "a photograph was given the reference photograph"
        )

        let tools = try Self.openEffects(on: screen)
        try await Harness.settle(until: { screen.editor.effectsMode.debugCardsAreDressed })
        let pill = try #require(tools.debugPicture(for: .blur))
        var look = FrameLook.neutral
        look.effect = LookEffect(kind: .blur, intensity: MediaEffectsCatalog.previewIntensity)
        let pillScale = tools.traitCollection.displayScale
        let side = MediaEffectsToolsView.thumbnailSide
        #expect(
            PixelProbe.distance(pill, Self.card(from: own, side: side, scale: pillScale, wearing: look)) < 0.02,
            "the pill is not the author's own picture"
        )
        #expect(
            PixelProbe.distance(
                pill, Self.card(from: reference, side: side, scale: pillScale, wearing: look)
            ) > 0.2,
            "a photograph was given the reference photograph"
        )
    }

    // MARK: - Swiping between the two

    /// ⚠️ **A CHANGE OF MEDIUM RE-DRESSES THE CARDS.** The effect pills are
    /// rendered once per `CardsSource` and kept; a key that did not know which
    /// picture dressed them would leave a photograph's cards standing over a
    /// clip, or the other way about — which is the same blank-card bug wearing
    /// the previous page's colours.
    @Test func swipingFromAPhotographToAVideoRedressesTheCards() async throws {
        let screen = Self.open([false, true])
        let reference = try #require(MediaLookReference.picture)
        try await Harness.settle(until: { screen.editor.heldPicture?.id == "photo-0" })
        let tools = try Self.openEffects(on: screen)
        try await Harness.settle(until: { screen.editor.effectsMode.debugCardsAreDressed })
        let onThePhotograph = try #require(tools.debugPicture(for: .blur))

        screen.editor.debugScrollToPage(1)
        screen.window.layoutIfNeeded()
        try await Harness.settle(until: {
            tools.debugPicture(for: .blur).map { PixelProbe.distance($0, onThePhotograph) > 0.2 } == true
        })

        let onTheVideo = try #require(tools.debugPicture(for: .blur))
        var look = FrameLook.neutral
        look.effect = LookEffect(kind: .blur, intensity: MediaEffectsCatalog.previewIntensity)
        let scale = tools.traitCollection.displayScale
        let side = MediaEffectsToolsView.thumbnailSide
        #expect(
            PixelProbe.distance(onTheVideo, Self.card(from: reference, side: side, scale: scale, wearing: look)) < 0.02,
            "the video's pills are not the reference photograph"
        )
        #expect(PixelProbe.distance(onTheVideo, onThePhotograph) > 0.2,
                "the photograph's pills stood over the clip")
    }
}
